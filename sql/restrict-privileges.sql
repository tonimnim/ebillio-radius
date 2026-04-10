-- Principle of least privilege for the FreeRADIUS MySQL user.
--
-- The 'radius' user is created by the mysql:8.0 entrypoint from the
-- MYSQL_USER / MYSQL_PASSWORD env vars with a blanket GRANT ALL on
-- radius.*. This script revokes that blanket grant and replaces it
-- with table-specific privileges that match exactly what FreeRADIUS
-- needs at runtime — nothing more.
--
-- Rationale: if the RADIUS server (or a NAS-supplied attribute) is
-- ever coerced into issuing an unexpected query, the blast radius is
-- limited to what each table legitimately needs. In particular:
--   * Authorization tables are read-only from FreeRADIUS's perspective;
--     they are managed by the web admin app out-of-band.
--   * radacct is the only table that needs UPDATE/DELETE (accounting
--     interim-updates overwrite the open session row, and session
--     cleanup may prune stale rows).
--   * radpostauth is append-only: post-auth logging should never be
--     able to rewrite or erase its own audit trail.
--   * Any future admin/ops tables added to the radius schema are
--     NOT granted here by default — they must be explicitly listed.
--
-- TLS: REQUIRE SSL forces the radius user to connect over a TLS
-- channel. MySQL 8 auto-generates self-signed certs on first start
-- and the server is launched with --ssl-cert/--ssl-key/--ssl-ca, so
-- TLS is available on the docker bridge. The FreeRADIUS sql module
-- (mods-available/sql → sql.template) must be configured with
-- matching client TLS settings or authentication will fail with
-- "Access denied ... SSL connection required".

REVOKE ALL PRIVILEGES ON radius.* FROM 'radius'@'%';

-- Read-only authorization / policy tables
GRANT SELECT ON radius.radcheck      TO 'radius'@'%';
GRANT SELECT ON radius.radreply      TO 'radius'@'%';
GRANT SELECT ON radius.radgroupcheck TO 'radius'@'%';
GRANT SELECT ON radius.radgroupreply TO 'radius'@'%';
GRANT SELECT ON radius.radusergroup  TO 'radius'@'%';
GRANT SELECT ON radius.nas           TO 'radius'@'%';

-- Accounting: interim-updates rewrite the open session row,
-- session cleanup may delete stale entries.
GRANT INSERT, UPDATE, DELETE ON radius.radacct TO 'radius'@'%';

-- Post-auth audit log: append-only. No UPDATE, no DELETE — ever.
GRANT INSERT ON radius.radpostauth TO 'radius'@'%';

-- Require TLS for this account. DISABLED on first deploy because
-- freeradius/sql.template does not yet have matching TLS client
-- options - enabling this without that change will lock FreeRADIUS
-- out of MySQL with "Access denied ... SSL connection required".
--
-- To enable: first add a `tls { tls_required = yes }` block to
-- freeradius/sql.template under the `mysql {}` subsection, redeploy
-- the freeradius container, verify auth still works, THEN uncomment
-- the line below and re-run this script.
-- ALTER USER 'radius'@'%' REQUIRE SSL;

FLUSH PRIVILEGES;
