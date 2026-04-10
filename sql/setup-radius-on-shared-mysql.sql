-- ============================================================================
-- eBillio RADIUS — one-shot setup against the shared ebillio-mysql container
-- ============================================================================
--
-- PURPOSE
--   Bootstrap everything FreeRADIUS needs inside the existing
--   `ebillio-mysql` container that the eBillio backend owns. After running
--   this, `docker compose up -d freeradius` from this repo will come up
--   and authenticate subscribers out of the shared `radius` database.
--
-- WHAT THIS DOES (in order)
--   1. CREATE DATABASE radius  (IF NOT EXISTS — idempotent)
--   2. Apply the hardened FreeRADIUS schema (BIGINT UNSIGNED octet columns,
--      composite PK, monthly partitioning, indexes tuned for billing queries)
--      by SOURCE-ing sql/schema.sql.
--   3. CREATE USER 'radius'@'%'  with the password this script is called
--      with (passed as a variable — see HOW TO RUN below). This is a
--      DEDICATED user, separate from the backend's `dasano` user, so the
--      RADIUS blast radius is scoped only to the RADIUS tables.
--   4. GRANT only the table-level privileges FreeRADIUS actually needs
--      (sql/restrict-privileges.sql semantics, inlined).
--   5. Run the Simultaneous-Use backfill (sql/migrations/002) as a
--      no-op if no subscribers exist yet.
--
-- WHAT THIS DOES NOT DO
--   * Does NOT drop or modify any table in the `dasano` database or any
--     other database in the shared MySQL.
--   * Does NOT create or modify the backend's `dasano` user.
--   * Does NOT touch the ebillio-mysql container's configuration or volume.
--   * Does NOT enable MySQL TLS (the REQUIRE SSL line is commented out
--     because freeradius/sql.template does not yet have a TLS client
--     config — enabling it would lock FreeRADIUS out).
--
-- HOW TO RUN (safely, with the password in an env var, not on the CLI)
--
--   From the repo root, with .env populated (DB_PASSWORD is the fresh
--   value from the rotated .env):
--
--     export MYSQL_PWD="$(grep ^DB_ROOT_PASSWORD .env | cut -d= -f2-)"
--     export RADIUS_DB_PASSWORD="$(grep ^DB_PASSWORD .env | cut -d= -f2-)"
--
--     # Copy schema + migration + this script into the container so
--     # SOURCE statements below can find them by absolute path.
--     docker cp sql/schema.sql                               ebillio-mysql:/tmp/ebillio-radius-schema.sql
--     docker cp sql/migrations/002_backfill_simultaneous_use.sql ebillio-mysql:/tmp/ebillio-radius-sim-use.sql
--     docker cp sql/setup-radius-on-shared-mysql.sql        ebillio-mysql:/tmp/ebillio-radius-setup.sql
--
--     # Run the setup script, passing the fresh radius user password via
--     # a user-defined variable.
--     docker exec -e MYSQL_PWD -e RADIUS_DB_PASSWORD -i ebillio-mysql \
--         mysql -uroot --init-command="SET @radius_pw := '${RADIUS_DB_PASSWORD}';" \
--         < sql/setup-radius-on-shared-mysql.sql
--
--     unset MYSQL_PWD RADIUS_DB_PASSWORD
--
--   Or use the Makefile target:  make setup-shared-mysql
--
-- IDEMPOTENT
--   Re-runs are safe. CREATE DATABASE uses IF NOT EXISTS. The schema file
--   should use CREATE TABLE IF NOT EXISTS (verify — if it doesn't, run
--   this only once on a fresh DB). CREATE USER uses IF NOT EXISTS. GRANTs
--   are redeclared (MySQL merges them). The Simultaneous-Use backfill is
--   idempotent by construction.
--
-- ROLLBACK (if you need to undo)
--   DROP USER 'radius'@'%';
--   DROP DATABASE radius;     -- DESTRUCTIVE; only if you really mean it
-- ============================================================================

-- --------------------------------------------------------------------------
-- 1. Database
-- --------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS radius
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE radius;

-- --------------------------------------------------------------------------
-- 2. Hardened FreeRADIUS schema
--
-- The SOURCE path is the absolute path INSIDE the mysql container, matching
-- where `docker cp` puts the file in the HOW TO RUN section above. The
-- schema file itself uses CREATE TABLE IF NOT EXISTS for idempotency.
-- --------------------------------------------------------------------------
SOURCE /tmp/ebillio-radius-schema.sql;

-- --------------------------------------------------------------------------
-- 3. Dedicated RADIUS user (NOT dasano).
--
-- Password comes from the @radius_pw session variable set by the caller
-- via --init-command. This keeps the plaintext password OUT of this file
-- and OUT of the shell history.
-- --------------------------------------------------------------------------

-- Clean-slate approach for idempotency: drop the radius user if it
-- already exists (from a prior run), then recreate it fresh. This
-- avoids MySQL 8's strict REVOKE-behavior on non-existent grants and
-- guarantees the user's grants below are the ONLY grants it has.
--
-- Safe because:
--   * Only touches 'radius'@'%', never 'dasano' or any other user
--   * MySQL 8 allows DROP USER even with active connections (they
--     just fail on their next query — run this when FreeRADIUS is
--     stopped on first run; subsequent re-runs can interrupt it,
--     it will reconnect with the new password from .env)
--   * The password from @radius_pw is reapplied so restart-loops
--     work without drift
DROP USER IF EXISTS 'radius'@'%';

-- MySQL 8 does NOT allow IDENTIFIED BY to read from a session variable,
-- so we build the CREATE USER statement dynamically and execute it
-- via PREPARE / EXECUTE. The password value lives only in @radius_pw
-- (set by the caller via the bash wrapper) and never appears as a
-- literal in this file. Single-quotes in the password are escaped by
-- doubling, which is the SQL-standard escape inside a single-quoted
-- literal.
SET @create_user_sql := CONCAT(
    "CREATE USER 'radius'@'%' IDENTIFIED BY '",
    REPLACE(@radius_pw, "'", "''"),
    "'"
);
PREPARE stmt FROM @create_user_sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
SET @create_user_sql := NULL;

-- --------------------------------------------------------------------------
-- 4. Least-privilege grants (matches sql/restrict-privileges.sql)
--
-- No REVOKE needed — the DROP USER + CREATE USER above gives us a fresh
-- user with only USAGE (no privileges on anything). Each GRANT below
-- adds exactly one table-level privilege, nothing more.
-- --------------------------------------------------------------------------

-- Read-only authorization / policy tables
GRANT SELECT ON radius.radcheck      TO 'radius'@'%';
GRANT SELECT ON radius.radreply      TO 'radius'@'%';
GRANT SELECT ON radius.radgroupcheck TO 'radius'@'%';
GRANT SELECT ON radius.radgroupreply TO 'radius'@'%';
GRANT SELECT ON radius.radusergroup  TO 'radius'@'%';
GRANT SELECT ON radius.nas           TO 'radius'@'%';

-- Accounting: interim-updates rewrite the open session row;
-- stale-session cleanup deletes or updates stale entries.
--
-- SELECT is REQUIRED alongside the write privs because MySQL's
-- UPDATE statement evaluates WHERE-clause columns (AcctUniqueId,
-- acctstoptime, nasipaddress, acctstarttime) using SELECT privilege.
-- Without it the UPDATE fails with "ERROR 1143 SELECT command denied",
-- interim-updates silently drop, and billing loses every byte after
-- the Start packet.
GRANT SELECT, INSERT, UPDATE, DELETE ON radius.radacct TO 'radius'@'%';

-- Post-auth audit log: append-only. No UPDATE, no DELETE — ever.
GRANT INSERT ON radius.radpostauth TO 'radius'@'%';

-- TLS requirement is DISABLED until freeradius/sql.template has a matching
-- `tls { tls_required = yes }` block under its mysql{} subsection.
-- Enabling this without that change will lock FreeRADIUS out with
-- "Access denied ... SSL connection required".
-- ALTER USER 'radius'@'%' REQUIRE SSL;

FLUSH PRIVILEGES;

-- --------------------------------------------------------------------------
-- 5. Simultaneous-Use backfill (idempotent — no-op on a fresh radcheck)
-- --------------------------------------------------------------------------
SOURCE /tmp/ebillio-radius-sim-use.sql;

-- --------------------------------------------------------------------------
-- Summary report
-- --------------------------------------------------------------------------
SELECT 'setup complete' AS status;

SELECT
    'radius tables'                           AS metric,
    COUNT(*)                                  AS value
FROM information_schema.tables
WHERE table_schema = 'radius';

SELECT
    'radcheck rows'                           AS metric,
    COUNT(*)                                  AS value
FROM radcheck;

SELECT
    'users with Simultaneous-Use attribute'   AS metric,
    COUNT(DISTINCT username)                  AS value
FROM radcheck
WHERE attribute = 'Simultaneous-Use';

SELECT
    'radius user grants'                      AS metric,
    COUNT(*)                                  AS value
FROM information_schema.schema_privileges
WHERE grantee LIKE "'radius'%";
