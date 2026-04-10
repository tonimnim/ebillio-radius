-- =============================================================================
-- Migration 002: Backfill Simultaneous-Use := 1 into radcheck
-- =============================================================================
--
-- WHY
--   freeradius/default has a `session { sql }` block that enforces
--   Simultaneous-Use against open rows in radacct. FreeRADIUS only fires
--   that block when the user has a `Simultaneous-Use` check attribute in
--   radcheck. Without this attribute, account sharing is unrestricted -
--   one credential can be used from many devices simultaneously, which
--   is the #1 way ISPs lose revenue to credential resale.
--
--   This migration sets `Simultaneous-Use := 1` for every existing
--   subscriber in radcheck so the session{} block becomes effective
--   immediately after deploy.
--
-- WHAT IT DOES
--   For every distinct username in radcheck that does NOT already have
--   a Simultaneous-Use row, INSERT one with op=':=' value='1'. Idempotent
--   - safe to re-run.
--
-- WHAT IT DOES NOT DO
--   * Does not change FreeRADIUS config (already done in feature/hardening-pass-1).
--   * Does not affect users who already have a Simultaneous-Use row (e.g.
--     premium plans permitting >1 device). Those rows stay untouched.
--   * Does not delete or update anything destructive.
--   * Does not touch the Railway billing app's provisioning code - that
--     change is required separately so NEW subscribers also get the
--     attribute. See docs/SIMULTANEOUS_USE.md for the code change.
--
-- HOW TO RUN
--   docker exec -i radius-mysql mysql -uroot -p"$DB_ROOT_PASSWORD" radius \
--       < sql/migrations/002_backfill_simultaneous_use.sql
--
--   Or via the Makefile:
--       make backfill-simultaneous-use   # add this target if you want
--
-- ROLLBACK
--   DELETE FROM radcheck
--   WHERE attribute = 'Simultaneous-Use'
--     AND value = '1'
--     AND op = ':=';
--   (only undo if you really want unrestricted concurrent logins)
--
-- VERIFICATION
--   After running, this query should return 0:
--     SELECT COUNT(DISTINCT username) FROM radcheck
--     WHERE username NOT IN (
--       SELECT DISTINCT username FROM radcheck WHERE attribute='Simultaneous-Use'
--     );
-- =============================================================================

INSERT INTO radcheck (username, attribute, op, value)
SELECT DISTINCT rc.username, 'Simultaneous-Use', ':=', '1'
FROM radcheck rc
WHERE NOT EXISTS (
    SELECT 1 FROM radcheck rc2
    WHERE rc2.username = rc.username
      AND rc2.attribute = 'Simultaneous-Use'
);

-- Report what was done
SELECT
    'Simultaneous-Use rows after migration' AS metric,
    COUNT(*) AS value
FROM radcheck
WHERE attribute = 'Simultaneous-Use';

SELECT
    'Distinct usernames in radcheck' AS metric,
    COUNT(DISTINCT username) AS value
FROM radcheck;
