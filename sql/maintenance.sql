-- =============================================================================
-- eBillio RADIUS — radacct maintenance queries
-- =============================================================================
--
-- Purpose: keep the `radacct` table sane when sessions end abnormally.
--
-- Background
-- ----------
-- FreeRADIUS inserts a row in `radacct` on Accounting-Start and expects a
-- matching Accounting-Stop to set `acctstoptime`. When a NAS reboots, loses
-- power, or a session drops without a Stop packet, the row stays open
-- (`acctstoptime IS NULL`) forever. That has two consequences:
--
--   1. Simultaneous-Use checks (the session{} block in freeradius/default)
--      count those zombie rows as "currently online" and reject legitimate
--      re-authentication attempts — the user gets locked out after their
--      router reboots.
--   2. Billing/reporting code that sums `acctsessiontime` will under- or
--      over-count usage for the affected sessions.
--
-- These queries are derived from networkradius's reference
-- `process-radacct.sql` (see FreeRADIUS raddb/mods-config/sql/main/mysql/
-- process-radacct.sql). They are tuned for eBillio's schema and indexes
-- (`idx_radacct_active`, `idx_radacct_nas_active`).
--
-- Usage
-- -----
--   * Query 1 (close stale sessions) runs every ~5 minutes from cron via
--     scripts/cleanup-stale-sessions.sh.
--   * Query 2 (close all sessions for a NAS) is parameterized — call it
--     manually, from an ops tool, or from an Accounting-On trigger if your
--     NAS does not emit Accounting-On reliably. FreeRADIUS's built-in
--     `accounting { sql }` already handles Accounting-On/Off for well-
--     behaved NAS devices; this is a fallback.
--   * Query 3 is a read-only diagnostic. Run it weekly to flag accounts
--     that are likely shared (credential reselling).
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Query 1: Close stale sessions
-- -----------------------------------------------------------------------------
-- Any open session that has not received an Interim-Update in the last 15
-- minutes is assumed dead. We synthesize a stop time of
-- (last acctupdatetime + 300 seconds) — i.e. one Interim-Update interval
-- after the last heartbeat, which is the most defensible estimate of when
-- the session actually ended. `acctsessiontime` is recomputed from the
-- start/update delta so billing has a consistent total.
--
-- Schedule: every 5 minutes via scripts/cleanup-stale-sessions.sh.
-- -----------------------------------------------------------------------------
UPDATE radacct
SET acctstoptime = DATE_ADD(acctupdatetime, INTERVAL 300 SECOND),
    acctterminatecause = 'NAS-Reboot',
    acctsessiontime = TIMESTAMPDIFF(SECOND, acctstarttime, acctupdatetime)
WHERE acctstoptime IS NULL
  AND acctupdatetime < NOW() - INTERVAL 15 MINUTE;


-- -----------------------------------------------------------------------------
-- Query 2: Close all open sessions for a single NAS
-- -----------------------------------------------------------------------------
-- Run this when a NAS sends Accounting-On (boot notification) — every open
-- session on that NAS is, by definition, stale. FreeRADIUS's sqlippool /
-- accounting module does this automatically via its Accounting-On/Off
-- handlers if `accounting { sql }` is wired in raddb/sites-enabled/default
-- (it is in eBillio's config). This query exists as an ops fallback for
-- when a NAS crashes without sending Accounting-On.
--
-- Parameter: nasipaddress (string, IPv4)
--
-- Example (from mysql CLI):
--   SET @nas = '10.0.0.17';
--   UPDATE radacct
--   SET acctstoptime = NOW(),
--       acctterminatecause = 'NAS-Reboot'
--   WHERE acctstoptime IS NULL
--     AND nasipaddress = @nas;
-- -----------------------------------------------------------------------------
UPDATE radacct
SET acctstoptime = NOW(),
    acctterminatecause = 'NAS-Reboot'
WHERE acctstoptime IS NULL
  AND nasipaddress = ?;


-- -----------------------------------------------------------------------------
-- Query 3: Detect possibly-fraudulent shared accounts
-- -----------------------------------------------------------------------------
-- Read-only diagnostic. A legitimate subscriber normally authenticates from
-- one or two devices on one NAS. Accounts seen from >3 distinct MACs or
-- >2 distinct NAS devices in a week are strong candidates for credential
-- sharing / resale. Review manually before taking action — roaming users
-- and households with many devices can false-positive.
-- -----------------------------------------------------------------------------
SELECT username,
       COUNT(DISTINCT callingstationid) AS distinct_macs,
       COUNT(DISTINCT nasipaddress)     AS distinct_nases
FROM radacct
WHERE acctstarttime > NOW() - INTERVAL 7 DAY
GROUP BY username
HAVING distinct_macs > 3 OR distinct_nases > 2;
