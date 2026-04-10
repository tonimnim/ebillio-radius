-- ============================================================================
-- Removes everything seeded by sql/seed-test-data.sql.
-- Scoped strictly by the `testuser-` / `testgroup-` / `test_localhost`
-- prefixes so production data is never touched.
--
-- Apply via:
--   docker exec -i radius-mysql mysql -uroot -p"$DB_ROOT_PASSWORD" radius \
--       < sql/clean-test-data.sql
-- or:  make clean-test-data
-- ============================================================================

USE radius;

-- radcheck / radreply  --  all test users
DELETE FROM radcheck  WHERE username LIKE 'testuser-%';
DELETE FROM radreply  WHERE username LIKE 'testuser-%';

-- radusergroup mappings
DELETE FROM radusergroup WHERE username LIKE 'testuser-%';
DELETE FROM radusergroup WHERE groupname LIKE 'testgroup-%';

-- group tables
DELETE FROM radgroupcheck WHERE groupname LIKE 'testgroup-%';
DELETE FROM radgroupreply WHERE groupname LIKE 'testgroup-%';

-- NAS entry
DELETE FROM nas WHERE shortname = 'test_localhost';

-- Accounting rows left over from test-accounting.sh runs
DELETE FROM radacct   WHERE username  LIKE 'testuser-%';
DELETE FROM radacct   WHERE acctsessionid LIKE 'test-%';

-- Post-auth log rows from test-auth.sh runs
DELETE FROM radpostauth WHERE username LIKE 'testuser-%';
