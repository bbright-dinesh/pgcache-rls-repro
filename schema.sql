-- Four tables with the same rows, differing only in their row-security rule.
--   tickets_plain     no row security
--   tickets_inline    the rule written out in place: column = current_setting(...)
--   tickets_fn        the same rule through a STABLE SQL function
--   tickets_volatile  the same rule, OR a VOLATILE plpgsql function (an audit
--                     hook that returns false unless a setting turns it on)
-- 2,000 tenants, 100 rows each. The reads log in as "app", which is not a
-- superuser and does not own the tables, so row security applies to it.

CREATE ROLE app LOGIN PASSWORD 'app';

-- the tenant of this session or transaction: SET [LOCAL] app.tenant = '42'
CREATE FUNCTION my_tenant() RETURNS text LANGUAGE sql STABLE AS $$
    SELECT nullif(current_setting('app.tenant', true), '')
$$;

CREATE TABLE tickets_fn (
    id        bigint PRIMARY KEY,
    tenant_id int    NOT NULL,
    status    text   NOT NULL,
    title     text   NOT NULL
);
INSERT INTO tickets_fn
SELECT g, 1 + g % 2000, CASE WHEN g % 5 = 0 THEN 'OPEN' ELSE 'CLOSED' END, 'ticket ' || g
FROM generate_series(1, 200000) g;
CREATE INDEX ON tickets_fn (tenant_id);

CREATE TABLE tickets_inline (LIKE tickets_fn INCLUDING ALL);
INSERT INTO tickets_inline SELECT * FROM tickets_fn;

CREATE TABLE tickets_plain (LIKE tickets_fn INCLUDING ALL);
INSERT INTO tickets_plain SELECT * FROM tickets_fn;

ALTER TABLE tickets_fn ENABLE ROW LEVEL SECURITY;
CREATE POLICY own_rows ON tickets_fn FOR SELECT
    USING (tenant_id::text = my_tenant());

ALTER TABLE tickets_inline ENABLE ROW LEVEL SECURITY;
CREATE POLICY own_rows ON tickets_inline FOR SELECT
    USING (tenant_id::text = current_setting('app.tenant', true));

-- the audit hook: off unless SET app.audit = 'on'; then it lets the row through and says so
CREATE FUNCTION audit(p_what text) RETURNS boolean LANGUAGE plpgsql VOLATILE AS $$
BEGIN
    IF coalesce(current_setting('app.audit', true), '') <> 'on' THEN
        RETURN false;
    END IF;
    RAISE WARNING 'audit: %', p_what;
    RETURN true;
END;
$$;

CREATE TABLE tickets_volatile (LIKE tickets_fn INCLUDING ALL);
INSERT INTO tickets_volatile SELECT * FROM tickets_fn;
ALTER TABLE tickets_volatile ENABLE ROW LEVEL SECURITY;
CREATE POLICY own_rows ON tickets_volatile FOR SELECT
    USING (tenant_id::text = my_tenant() OR audit('tickets_volatile read'));

GRANT SELECT ON tickets_fn, tickets_inline, tickets_plain, tickets_volatile TO app;
ANALYZE;
