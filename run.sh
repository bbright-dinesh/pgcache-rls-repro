#!/bin/bash
# The same read, CLIENTS clients for DURATION seconds, on four tables that
# differ only in their row-security rule, straight to Postgres and through
# pgcache. Prints requests per second, average latency, and what pgcache's own
# counters did meanwhile.
#   ./run.sh            a fresh stack, eight runs, summary in out/summary.txt
#   CLIENTS=40 DURATION=30 OUT=out PGCACHE_IMAGE=pgcache/pgcache:latest ./run.sh
# Needs: docker (with compose), curl, awk.
set -euo pipefail
cd "$(dirname "$0")"
CLIENTS=${CLIENTS:-40}
DURATION=${DURATION:-30}
C="docker compose -p pgcache-rls-repro"
X="docker exec -i pgcache-rls-repro-primary-1"
out=${OUT:-out}
mkdir -p "$out"

$C down -v > /dev/null 2>&1 || true
$C up -d
printf 'waiting for pgcache'
for _ in $(seq 120); do
    curl -fs -o /dev/null http://127.0.0.1:9099/readyz && break
    [ -n "$(docker ps -q -f name=pgcache-rls-repro-pgcache-1)" ] || { echo; docker logs --tail 20 pgcache-rls-repro-pgcache-1; exit 1; }
    printf .; sleep 2
done
curl -fs -o /dev/null http://127.0.0.1:9099/readyz || { echo " never ready"; exit 1; }
echo " ready"
sleep 10   # settle: pgcache's stream from the origin

metrics() { curl -fs http://127.0.0.1:9099/metrics | grep -E '^pgcache_' | grep -v quantile | sort; }
delta() {  # before after name → how far that counter moved
    awk -v n="$3" 'FNR == NR { if ($1 == n) a = $2; next } $1 == n { b = $2 } END { printf "%.6g", b - a }' "$1" "$2"
}

for t in tickets_plain tickets_inline tickets_fn tickets_volatile; do
    $X sh -c "cat > /tmp/$t.sql" <<SQL
BEGIN READ ONLY;
SET LOCAL app.tenant = '42';
SELECT id, status FROM $t WHERE tenant_id = 42;
COMMIT;
SQL
done

run() {  # table host
    local name="$1 via $2" f="$out/$1.$2"
    metrics > "$f.before"
    $X pgbench -n -M extended -c "$CLIENTS" -j 4 -T "$DURATION" -f "/tmp/$1.sql" \
        "postgres://app:app@$2:5432/repro" > "$f.txt" 2>&1 || true
    sleep 1
    metrics > "$f.after"
    local R='pgcache_cache_writer_command_handle_seconds'
    printf '%-30s %8s tps  %9s ms | hit %7s  miss %7s  rls_skipped %7s | writer resolves %7s taking %6.1f s\n' "$name" \
        "$(awk '/^tps/ {printf "%.0f", $3}' "$f.txt")" \
        "$(awk '/latency average/ {print $4}' "$f.txt")" \
        "$(delta "$f.before" "$f.after" pgcache_queries_cache_hit)" \
        "$(delta "$f.before" "$f.after" pgcache_queries_cache_miss)" \
        "$(delta "$f.before" "$f.after" pgcache_queries_rls_skipped)" \
        "$(delta "$f.before" "$f.after" "${R}_count{cmd=\"resolve\"}")" \
        "$(delta "$f.before" "$f.after" "${R}_sum{cmd=\"resolve\"}")" | tee -a "$out/summary.txt"
}

{
    echo "pgcache image: $(docker inspect pgcache-rls-repro-pgcache-1 --format '{{.Image}}')"
    echo "clients $CLIENTS, $DURATION s each, pgbench -M extended; each database 2 CPUs, 3 GB"
} | tee "$out/summary.txt"
for t in tickets_plain tickets_inline tickets_fn tickets_volatile; do
    run "$t" primary
    run "$t" pgcache
done
echo "done: $out/summary.txt (pgbench output and pgcache's counters before/after each run beside it)"
echo "stop the stack: $C down -v"
