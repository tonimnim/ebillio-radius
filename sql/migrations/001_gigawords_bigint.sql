-- =============================================================================
-- Migration 001: gigawords-safe octet columns + billing indexes on radacct
-- =============================================================================
--
-- WHO SHOULD RUN THIS
-- -----------------------------------------------------------------------------
-- Deployments that were created from the ORIGINAL eBillio schema.sql (before
-- the gigawords/billing-correctness fix) and therefore have:
--   * `acctinputoctets`  as signed `BIGINT NULL DEFAULT NULL`
--   * `acctoutputoctets` as signed `BIGINT NULL DEFAULT NULL`
--   * No composite (username, acctstarttime) / (nasipaddress, acctstarttime)
--     indexes, and no standalone (acctstoptime) index.
--
-- Fresh deployments created from the updated schema.sql do NOT need this
-- migration -- they are already correct.
--
-- WHAT THIS FIXES
-- -----------------------------------------------------------------------------
-- RADIUS transmits session byte counts as (Gigawords, Octets) pairs because
-- Acct-Input-Octets is a 32-bit counter that wraps every 4 GiB. The true
-- byte count is `(Gigawords << 32) | Octets`. FreeRADIUS 3.2.x queries.conf
-- already computes that combined value on the INSERT / UPDATE side, but the
-- original schema stored octets as *signed* BIGINT with a NULL default. This
-- migration widens them to BIGINT UNSIGNED NOT NULL DEFAULT 0 to match the
-- semantics of a byte counter and to avoid any sign-bit surprises in
-- downstream billing aggregation (SUM() rollups, etc).
--
-- This migration is NON-DESTRUCTIVE: no rows are deleted, and existing
-- non-negative octet values round-trip unchanged through the type change.
-- NULL octet values (from the old `DEFAULT NULL` column) will be coerced
-- to 0, which is the correct billing default for a session with no reported
-- traffic.
--
-- SAFETY
-- -----------------------------------------------------------------------------
-- * The ALTER TABLE statements rewrite `radacct` in place. On large tables
--   this can take a while and hold a metadata lock. Run during a maintenance
--   window, or use pt-online-schema-change / gh-ost for zero-downtime.
-- * The index-creation block is idempotent: it checks INFORMATION_SCHEMA
--   before each CREATE INDEX, so rerunning the migration is safe.
-- * This migration does NOT add partitioning. Converting an existing
--   non-partitioned radacct to a partitioned one is a heavy, table-rewriting
--   operation with its own constraints (every unique key must include the
--   partitioning column). See the separate partitioning playbook in
--   schema.sql if you want to migrate an existing table.
--
-- =============================================================================

USE radius;

-- -----------------------------------------------------------------------------
-- 1. Widen octet columns to BIGINT UNSIGNED NOT NULL DEFAULT 0.
-- -----------------------------------------------------------------------------
ALTER TABLE `radacct`
  MODIFY `acctinputoctets`  BIGINT(20) UNSIGNED NOT NULL DEFAULT 0;

ALTER TABLE `radacct`
  MODIFY `acctoutputoctets` BIGINT(20) UNSIGNED NOT NULL DEFAULT 0;

-- -----------------------------------------------------------------------------
-- 2. Add missing billing / reporting / cleanup indexes, idempotently.
--
-- MySQL 8.0 does not support `CREATE INDEX IF NOT EXISTS`, so we guard each
-- CREATE INDEX with an INFORMATION_SCHEMA check and a prepared statement.
-- -----------------------------------------------------------------------------

-- (username, acctstarttime) -- monthly per-subscriber usage aggregation.
SET @have_idx := (
  SELECT COUNT(*) FROM information_schema.statistics
  WHERE table_schema = DATABASE()
    AND table_name   = 'radacct'
    AND index_name   = 'idx_radacct_user_start'
);
SET @sql := IF(@have_idx = 0,
  'CREATE INDEX idx_radacct_user_start ON radacct (username, acctstarttime)',
  'DO 0');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- (nasipaddress, acctstarttime) -- per-NAS historical reporting.
SET @have_idx := (
  SELECT COUNT(*) FROM information_schema.statistics
  WHERE table_schema = DATABASE()
    AND table_name   = 'radacct'
    AND index_name   = 'idx_radacct_nas_start'
);
SET @sql := IF(@have_idx = 0,
  'CREATE INDEX idx_radacct_nas_start ON radacct (nasipaddress, acctstarttime)',
  'DO 0');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- (acctstoptime) -- stale / unclosed session cleanup sweeps.
SET @have_idx := (
  SELECT COUNT(*) FROM information_schema.statistics
  WHERE table_schema = DATABASE()
    AND table_name   = 'radacct'
    AND index_name   = 'acctstoptime'
);
SET @sql := IF(@have_idx = 0,
  'CREATE INDEX acctstoptime ON radacct (acctstoptime)',
  'DO 0');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Sanity: acctuniqueid MUST be UNIQUE. FreeRADIUS 3.2.x's queries.conf uses
-- an UPDATE-then-INSERT fallthrough pattern keyed on AcctUniqueId, and the
-- UNIQUE constraint is the only thing stopping lost-Stop / racey duplicate
-- inserts from double-counting bytes. The original schema already declares
-- it as UNIQUE KEY, so we only assert it here -- failing loudly beats
-- silently double-inserting accounting rows.
SET @have_unique := (
  SELECT COUNT(*) FROM information_schema.statistics
  WHERE table_schema = DATABASE()
    AND table_name   = 'radacct'
    AND index_name   = 'acctuniqueid'
    AND non_unique   = 0
);
SET @sql := IF(@have_unique = 0,
  'SIGNAL SQLSTATE ''45000'' SET MESSAGE_TEXT = ''radacct.acctuniqueid is not UNIQUE -- fix before proceeding; FreeRADIUS accounting uses INSERT ... ON DUPLICATE KEY UPDATE and requires this constraint''',
  'DO 0');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;
