-- =============================================================================
-- Migration 003: Hardening ALTER for an existing radacct table
-- =============================================================================
--
-- PURPOSE
--   Upgrade an existing (backend-migrated) radacct table to the hardened
--   schema that migration 001 would have produced on a fresh install:
--
--     * acctinputoctets / acctoutputoctets -> BIGINT UNSIGNED NOT NULL
--       DEFAULT 0. The signed default held up to ~9 EB per session so
--       runtime overflow was not a real risk, but unsigned matches the
--       semantics of byte counters and prevents accidental negative
--       aggregations in reporting queries.
--
--     * acctstarttime -> NOT NULL DEFAULT '1970-01-01 00:00:01'.
--       Required by MySQL partitioning — partition columns cannot be
--       nullable.
--
--     * PRIMARY KEY -> (radacctid, acctstarttime). Composite. Required
--       by MySQL's "every unique key must include the partition column"
--       rule. FreeRADIUS queries that key on radacctid alone still hit
--       the leftmost prefix of this index, so no application change.
--
--     * UNIQUE KEY `acctuniqueid` -> (acctuniqueid, acctstarttime).
--       Same partitioning constraint. Uniqueness is preserved because
--       Acct-Unique-Session-Id is already globally unique per session.
--
--     * New indexes for billing / reporting / stale-session cleanup:
--         idx_radacct_user_start    (username, acctstarttime)
--         idx_radacct_nas_start     (nasipaddress, acctstarttime)
--         idx_radacct_active        (username, acctstoptime)
--         idx_radacct_stop          (acctuniqueid, acctstoptime)
--         idx_radacct_nas_active    (nasipaddress, acctstoptime)
--
--     * RANGE partitioning on acctstarttime — 12 monthly partitions
--       plus a p_future catch-all. Enables DROP PARTITION for cheap
--       O(1) archival once radacct accumulates enough data.
--
-- WHEN TO RUN
--   On any existing deployment where the base FreeRADIUS schema is
--   already in place (i.e. this repo's sql/setup-radius-on-shared-mysql.sql
--   was a no-op on the CREATE TABLE statements because the backend's
--   migration had already created the tables).
--
-- SAFETY
--   * Checks partition state first and skips the ALTER if migration 003
--     has already been applied. Safe to re-run.
--   * The ALTER is executed as one atomic statement so MySQL rewrites
--     the table only once.
--   * On an EMPTY radacct, the rewrite is near-instant.
--   * On a populated radacct with N rows, the ALTER is still correct
--     but takes O(N) time and holds a metadata lock for the duration.
--     For N > 100k rows, run during a maintenance window and consider
--     pt-online-schema-change or gh-ost for zero-downtime rewrites.
--
-- HOW TO RUN
--   make hardening-alter         # idempotent, safe to re-run
--
--   Or manually (needs the shared-mysql root password):
--     docker exec -i -e MYSQL_PWD=<root-pw> ebillio-mysql \
--         mysql -uroot radius < sql/migrations/003_hardening_alter_existing_tables.sql
--
-- ROLLBACK
--   There is no single-command rollback. The column-type changes are
--   effectively one-way (UNSIGNED -> SIGNED loses the safety property).
--   Partitioning can be removed with `ALTER TABLE radacct REMOVE
--   PARTITIONING;`. Index removals are per-index DROP INDEX.
-- =============================================================================

-- ---- Preflight: warn if radacct is not empty ------------------------------
SELECT
    'radacct row count (ALTER will rewrite the table — large values = long downtime)'
        AS metric,
    COUNT(*) AS value
FROM radacct;

-- ---- Idempotency guard ----------------------------------------------------
SELECT COUNT(*)
INTO @already_partitioned
FROM information_schema.partitions
WHERE table_schema = 'radius'
  AND table_name   = 'radacct'
  AND partition_name IS NOT NULL;

SET @alter_sql := IF(
    @already_partitioned > 0,
    'SELECT "migration 003 already applied (radacct is partitioned) — skipping ALTER" AS status',
    CONCAT(
        'ALTER TABLE radacct ',
            'MODIFY acctinputoctets  BIGINT UNSIGNED NOT NULL DEFAULT 0, ',
            'MODIFY acctoutputoctets BIGINT UNSIGNED NOT NULL DEFAULT 0, ',
            'MODIFY acctstarttime    DATETIME NOT NULL DEFAULT ''1970-01-01 00:00:01'', ',
            'DROP PRIMARY KEY, ',
            'ADD PRIMARY KEY (radacctid, acctstarttime), ',
            'DROP INDEX acctuniqueid, ',
            'ADD UNIQUE KEY acctuniqueid (acctuniqueid, acctstarttime), ',
            'ADD INDEX idx_radacct_user_start  (username, acctstarttime), ',
            'ADD INDEX idx_radacct_nas_start   (nasipaddress, acctstarttime), ',
            'ADD INDEX idx_radacct_active      (username, acctstoptime), ',
            'ADD INDEX idx_radacct_stop        (acctuniqueid, acctstoptime), ',
            'ADD INDEX idx_radacct_nas_active  (nasipaddress, acctstoptime) ',
        'PARTITION BY RANGE (TO_DAYS(acctstarttime)) ( ',
            'PARTITION p2026_04 VALUES LESS THAN (TO_DAYS(''2026-05-01'')), ',
            'PARTITION p2026_05 VALUES LESS THAN (TO_DAYS(''2026-06-01'')), ',
            'PARTITION p2026_06 VALUES LESS THAN (TO_DAYS(''2026-07-01'')), ',
            'PARTITION p2026_07 VALUES LESS THAN (TO_DAYS(''2026-08-01'')), ',
            'PARTITION p2026_08 VALUES LESS THAN (TO_DAYS(''2026-09-01'')), ',
            'PARTITION p2026_09 VALUES LESS THAN (TO_DAYS(''2026-10-01'')), ',
            'PARTITION p2026_10 VALUES LESS THAN (TO_DAYS(''2026-11-01'')), ',
            'PARTITION p2026_11 VALUES LESS THAN (TO_DAYS(''2026-12-01'')), ',
            'PARTITION p2026_12 VALUES LESS THAN (TO_DAYS(''2027-01-01'')), ',
            'PARTITION p2027_01 VALUES LESS THAN (TO_DAYS(''2027-02-01'')), ',
            'PARTITION p2027_02 VALUES LESS THAN (TO_DAYS(''2027-03-01'')), ',
            'PARTITION p2027_03 VALUES LESS THAN (TO_DAYS(''2027-04-01'')), ',
            'PARTITION p_future VALUES LESS THAN MAXVALUE ',
        ')'
    )
);

PREPARE stmt FROM @alter_sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
SET @alter_sql := NULL;

-- ---- Verification report --------------------------------------------------
SELECT
    'radacct partition count after migration' AS metric,
    COUNT(*) AS value
FROM information_schema.partitions
WHERE table_schema = 'radius'
  AND table_name   = 'radacct'
  AND partition_name IS NOT NULL;

SELECT
    'acctinputoctets is unsigned' AS metric,
    IF(column_type LIKE '%unsigned%', 'YES', 'NO') AS value
FROM information_schema.columns
WHERE table_schema = 'radius'
  AND table_name   = 'radacct'
  AND column_name  = 'acctinputoctets';

SELECT
    'new indexes present' AS metric,
    COUNT(DISTINCT index_name) AS value
FROM information_schema.statistics
WHERE table_schema = 'radius'
  AND table_name   = 'radacct'
  AND index_name IN (
        'idx_radacct_user_start',
        'idx_radacct_nas_start',
        'idx_radacct_active',
        'idx_radacct_stop',
        'idx_radacct_nas_active'
      );
