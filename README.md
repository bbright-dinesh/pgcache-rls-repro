# pgcache: reads on a table whose RLS policy can't be inlined are slower than no proxy

A small, self-contained reproduction. One Postgres 16, one pgcache in front of
it, four tables with the same rows that differ only in their row-security
policy, and `pgbench` running the same read against each, straight to Postgres
and through pgcache.

## What it shows

When a table's policy cannot be inlined, pgcache (correctly) does not cache
reads on it. But every such read still goes through the single cache-writer
thread as a `resolve` command, and the "can't cache this" answer does not seem
to be remembered: the count of resolves equals the count of reads. With 40
clients the writer is busy for the whole run, the reads queue behind it, and
throughput drops **below** what Postgres gives with no proxy at all.

Build of 2026-11-21 (`pgcache/pgcache@sha256:821b027f…`), 40 clients, 30 s each:

| table | policy | Postgres direct | through pgcache | cache hits | `rls_skipped` | writer `resolve` commands |
|---|---|---|---|---|---|---|
| `tickets_plain` | none | 9,150 tps | 14,587 tps | 437,267 | 0 | 40 |
| `tickets_inline` | `tenant_id::text = current_setting('app.tenant', true)` | 7,545 tps | 13,927 tps | 417,353 | 0 | 40 |
| `tickets_fn` | the same through a `STABLE` SQL function | 7,149 tps | 14,536 tps | 435,417 | 0 | 40 |
| `tickets_volatile` | the same `OR` a `VOLATILE` plpgsql function | 7,309 tps | **4,246 tps** | 0 | 127,167 | **127,167, taking 29.9 s of the 30 s** |

Build of 2026-11-03 (`pgcache/pgcache@sha256:0b638207…`), same machine, same day:

| table | Postgres direct | through pgcache | cache hits | `rls_skipped` | writer `resolve` commands |
|---|---|---|---|---|---|
| `tickets_plain` | 8,865 tps | 15,068 tps | 450,836 | 0 | 40 |
| `tickets_inline` | 7,949 tps | 15,468 tps | 463,536 | 0 | 40 |
| `tickets_fn` | 7,723 tps | **4,961 tps** | 0 | 148,636 | **148,636, taking 29.9 s** |
| `tickets_volatile` | 7,283 tps | **5,140 tps** | 0 | 154,009 | **154,009, taking 29.9 s** |

So the newer build inlines a `STABLE` SQL function (thank you, that one is
fixed), and the same slowdown remains for any policy it still cannot inline.

The raw summaries are in [`results/`](results/).

## The ask

Not caching `tickets_volatile` is the right call. The request is only that the
skipped read be cheap: remember the "can't cache" verdict per query shape (or
per table), so that later reads on it are forwarded without another trip
through the cache writer. A skipped read should cost about what a plain
pass-through costs.

## Run it

Needs Docker with Compose, `curl` and `awk`. About 5 minutes.

```sh
git clone https://github.com/bbright-dinesh/pgcache-rls-repro
cd pgcache-rls-repro
./run.sh
```

It starts a fresh stack (`docker compose -p pgcache-rls-repro`), runs the eight
cases and prints one line per case; the same lines go to `out/summary.txt`, with
pgbench's output and pgcache's counters before and after each case beside it.

Knobs, all optional:

```sh
PGCACHE_IMAGE=pgcache/pgcache:latest ./run.sh     # another build (default: the 2026-11-21 build, by digest)
CLIENTS=40 DURATION=30 OUT=out ./run.sh           # the defaults
```

Stop and remove everything: `docker compose -p pgcache-rls-repro down -v`

## What is in it

- [`schema.sql`](schema.sql): the four tables (200,000 rows each, 2,000
  tenants), the two functions, the policies, and the `app` login the reads use
  (not a superuser, not the owner, so row security applies).
- [`docker-compose.yml`](docker-compose.yml): Postgres 16 (Debian image) and
  pgcache, each capped at 2 CPUs and 3 GB, `NUM_WORKERS=2`, telemetry off. Only
  pgcache's metrics are published on the host (`127.0.0.1:9099`).
- [`run.sh`](run.sh): for each table, `pgbench -n -M extended -c 40 -j 4 -T 30`
  of this transaction, against `primary` and then against `pgcache`:

  ```sql
  BEGIN READ ONLY;
  SET LOCAL app.tenant = '42';
  SELECT id, status FROM <table> WHERE tenant_id = 42;
  COMMIT;
  ```

  The columns it prints from pgcache's `/metrics`, as the change over the case:
  `pgcache_queries_cache_hit`, `pgcache_queries_cache_miss`,
  `pgcache_queries_rls_skipped`, and the count and sum of
  `pgcache_cache_writer_command_handle_seconds{cmd="resolve"}`.

## Where the numbers above are from

Mac mini, Apple M4 (10 cores), 16 GB, macOS 26.5, Docker Desktop (engine
28.3.2, Compose 2.38.2), linux/arm64 images. pgbench runs inside the Postgres
container, so it shares that container's 2 CPUs in every case alike. Absolute
numbers will differ on other machines; the shape (the last row falling below
"Postgres direct" while the writer is busy for the whole run) is the point.

## Two things noticed on the way

- The 2026-11-21 build refuses to start against `postgres:16-alpine` ("cache
  host orders text differently from origin"), which is why this uses the Debian
  image. Reasonable, and the message is clear.
- The 2026-11-21 image no longer has `wget`, so a Compose health check on
  `/readyz` from inside the container stops working; `run.sh` polls it from the
  host instead.

## Why we care

Our real policies have this shape: the tenant check, `OR` an audit hook that is
a `VOLATILE` plpgsql function returning false unless a setting turns it on. Under
a mixed application load the same effect made reads through pgcache several
times slower than the primary alone, with pgcache's CPU nearly idle.
