-- ============================================================================
-- TEST DATA ONLY  --  wipe with sql/clean-test-data.sql before production.
-- These users have weak passwords and predictable names.
--
-- Every row created here is prefixed with `testuser-` or `testgroup-` or
-- `test_localhost` so it can be safely identified and removed.
--
-- Apply via:
--   docker exec -i radius-mysql mysql -uroot -p"$DB_ROOT_PASSWORD" radius \
--       < sql/seed-test-data.sql
-- or:  make seed
--
-- NOTE on the NAS secret: the `nas` table's `secret` column MUST match the
-- RADIUS_SECRET env var that FreeRADIUS is running with, otherwise packets
-- from 127.0.0.1 will be rejected. The placeholder `__RADIUS_SECRET__` below
-- is rewritten at apply time by `make seed` / tests/run-all.sh using sed so
-- the real secret never lives on disk.
-- ============================================================================

USE radius;

-- ---------------------------------------------------------------------------
-- Users in radcheck
-- ---------------------------------------------------------------------------

-- 1) Plain PAP user, valid password.
INSERT INTO radcheck (username, attribute, op, value) VALUES
    ('testuser-pap', 'Cleartext-Password', ':=', 'testpass123');

-- 2) CHAP user. The Cleartext-Password is what FreeRADIUS compares against
--    when the NAS sends CHAP-Password; no separate CHAP attribute is needed.
INSERT INTO radcheck (username, attribute, op, value) VALUES
    ('testuser-chap', 'Cleartext-Password', ':=', 'testpass123');

-- 3) Blocked user  --  correct password but forced reject via Auth-Type.
INSERT INTO radcheck (username, attribute, op, value) VALUES
    ('testuser-blocked', 'Cleartext-Password', ':=', 'testpass123'),
    ('testuser-blocked', 'Auth-Type',          ':=', 'Reject');

-- ---------------------------------------------------------------------------
-- Group with a reply attribute  --  verifies the group/reply chain works
-- ---------------------------------------------------------------------------

-- A dummy check so the group exists (not strictly required for reply
-- delivery, but it mirrors how real plans are modeled in eBillio).
INSERT INTO radgroupcheck (groupname, attribute, op, value) VALUES
    ('testgroup-10mbps', 'Auth-Type', ':=', 'PAP');

INSERT INTO radgroupreply (groupname, attribute, op, value) VALUES
    ('testgroup-10mbps', 'Mikrotik-Rate-Limit', ':=', '10M/10M');

-- Map testuser-pap into the group so its Access-Accept carries the rate limit.
INSERT INTO radusergroup (username, groupname, priority) VALUES
    ('testuser-pap', 'testgroup-10mbps', 1);

-- ---------------------------------------------------------------------------
-- NAS entry  --  lets FreeRADIUS accept packets from 127.0.0.1 via the
-- dynamic (SQL-driven) client loader in addition to clients.conf.
-- ---------------------------------------------------------------------------
INSERT INTO nas (nasname, shortname, type, ports, secret, description) VALUES
    ('127.0.0.1', 'test_localhost', 'other', NULL, '__RADIUS_SECRET__',
     'Test harness localhost NAS  --  seed-test-data.sql');
