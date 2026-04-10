-- =============================================================================
-- eBillio FreeRADIUS schema (MySQL 8.0, FreeRADIUS 3.2.7)
-- =============================================================================
--
-- GIGAWORDS / 4 GiB BILLING CORRECTNESS NOTE
-- -----------------------------------------------------------------------------
-- RADIUS transmits session byte counts as a pair of attributes:
--   * Acct-Input-Octets     (32-bit, wraps at 2^32 = 4 GiB)
--   * Acct-Input-Gigawords  (32-bit, counts how many times Octets wrapped)
-- and likewise for output. The true byte count for a session is:
--   total = (Gigawords << 32) | Octets
-- If the accounting SQL stores only the Octets value, every session above
-- 4 GiB is silently undercharged -- a revenue bug for an ISP AAA system.
--
-- This schema sizes `acctinputoctets` / `acctoutputoctets` as
-- BIGINT UNSIGNED NOT NULL DEFAULT 0 so they can safely hold the combined
-- 64-bit value produced by `(Gigawords << 32) | Octets`.
--
-- The *actual* combination happens in the accounting INSERT/UPDATE queries
-- defined in the FreeRADIUS config file:
--     raddb/mods-config/sql/main/mysql/queries.conf
-- That file ships inside the upstream freeradius/freeradius-server image
-- (not in this repo). Good news: FreeRADIUS 3.2.x ships with gigawords-aware
-- queries OUT OF THE BOX. Verified against
-- https://github.com/FreeRADIUS/freeradius-server/blob/v3.2.x/raddb/mods-config/sql/main/mysql/queries.conf
-- where every radacct INSERT / UPDATE uses the form:
--     acctinputoctets  = '%{%{Acct-Input-Gigawords}:-0}'  << 32 | '%{%{Acct-Input-Octets}:-0}',
--     acctoutputoctets = '%{%{Acct-Output-Gigawords}:-0}' << 32 | '%{%{Acct-Output-Octets}:-0}'
--
-- OPERATIONAL REQUIREMENT: if you ever override queries.conf (bind-mount a
-- custom copy into the container, or switch to a derived image), you MUST
-- preserve the `<< 32 |` bitwise-OR form on BOTH start AND interim/stop
-- updates for BOTH input and output octets. Dropping it will silently
-- undercharge any session above 4 GiB.
--
-- Reference: NetworkRADIUS "Periodic Data Usage Reporting" howto
--   https://networkradius.com/doc/current/howto/modules/sql/data_usage.html
--
-- =============================================================================

USE radius;

CREATE TABLE IF NOT EXISTS `radcheck` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `username` varchar(64) NOT NULL DEFAULT '',
  `attribute` varchar(64) NOT NULL DEFAULT '',
  `op` char(2) NOT NULL DEFAULT '==',
  `value` varchar(253) NOT NULL DEFAULT '',
  PRIMARY KEY (`id`),
  KEY `username` (`username`(32))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `radreply` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `username` varchar(64) NOT NULL DEFAULT '',
  `attribute` varchar(64) NOT NULL DEFAULT '',
  `op` char(2) NOT NULL DEFAULT '=',
  `value` varchar(253) NOT NULL DEFAULT '',
  PRIMARY KEY (`id`),
  KEY `username` (`username`(32))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `radgroupcheck` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `groupname` varchar(64) NOT NULL DEFAULT '',
  `attribute` varchar(64) NOT NULL DEFAULT '',
  `op` char(2) NOT NULL DEFAULT '==',
  `value` varchar(253) NOT NULL DEFAULT '',
  PRIMARY KEY (`id`),
  KEY `groupname` (`groupname`(32))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `radgroupreply` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `groupname` varchar(64) NOT NULL DEFAULT '',
  `attribute` varchar(64) NOT NULL DEFAULT '',
  `op` char(2) NOT NULL DEFAULT '=',
  `value` varchar(253) NOT NULL DEFAULT '',
  PRIMARY KEY (`id`),
  KEY `groupname` (`groupname`(32))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `radusergroup` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `username` varchar(64) NOT NULL DEFAULT '',
  `groupname` varchar(64) NOT NULL DEFAULT '',
  `priority` int(11) NOT NULL DEFAULT '1',
  PRIMARY KEY (`id`),
  KEY `username` (`username`(32))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- -----------------------------------------------------------------------------
-- radacct -- session accounting
--
-- Notes on column types and indexes:
--   * acctinputoctets / acctoutputoctets are BIGINT UNSIGNED NOT NULL DEFAULT 0
--     so they can hold the combined (Gigawords << 32) | Octets value without
--     sign-bit ambiguity. See the gigawords note at the top of this file.
--   * Indexes are tuned for ISP billing workloads:
--       - UNIQUE(acctuniqueid, acctstarttime) -- data-integrity guard against
--                                                duplicate rows, and the
--                                                index used by FreeRADIUS's
--                                                UPDATE-by-AcctUniqueId path
--                                                in queries.conf (the leading
--                                                acctuniqueid prefix serves
--                                                the single-column lookup).
--       - (username, acctstarttime)           -- monthly "total usage per
--                                                subscriber" billing query.
--       - (acctstoptime)                      -- stale / unclosed session
--                                                cleanup sweeps.
--       - (nasipaddress, acctstarttime)       -- per-NAS reporting.
--       - (username, acctstoptime)            -- "active sessions for user".
--       - (nasipaddress, acctstoptime)        -- "active sessions on NAS"
--                                                (used by radzap / CoA).
--
-- Partitioning: see the PARTITION BY RANGE clause below. The table is
-- range-partitioned by MONTH(acctstarttime) so archival of old months is a
-- cheap metadata-only `ALTER TABLE ... DROP PARTITION`, instead of a slow
-- row-by-row DELETE that bloats the undo log and fragments InnoDB pages.
--
-- IMPORTANT MySQL PARTITIONING CONSTRAINT: every UNIQUE / PRIMARY key in a
-- partitioned table must include the partitioning column. We therefore
-- promote `acctstarttime` into the PRIMARY KEY and into the UNIQUE KEY on
-- `acctuniqueid`. This is compatible with FreeRADIUS 3.2.x's accounting
-- queries because they update by `AcctUniqueId` only (not by the composite
-- unique key) and the leading `acctuniqueid` column of the composite unique
-- index serves that lookup as a normal index prefix. `acctstarttime` is set
-- on Start and never changes on subsequent Interim/Stop updates for the
-- same session, so the composite unique key is stable for a given session.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `radacct` (
  `radacctid` bigint(21) NOT NULL AUTO_INCREMENT,
  `acctsessionid` varchar(64) NOT NULL DEFAULT '',
  `acctuniqueid` varchar(32) NOT NULL DEFAULT '',
  `username` varchar(64) NOT NULL DEFAULT '',
  `realm` varchar(64) DEFAULT '',
  `nasipaddress` varchar(15) NOT NULL DEFAULT '',
  `nasportid` varchar(32) DEFAULT NULL,
  `nasporttype` varchar(32) DEFAULT NULL,
  `acctstarttime` datetime NOT NULL DEFAULT '1970-01-01 00:00:01',
  `acctupdatetime` datetime DEFAULT NULL,
  `acctstoptime` datetime DEFAULT NULL,
  `acctinterval` int(12) DEFAULT NULL,
  `acctsessiontime` int(12) unsigned DEFAULT NULL,
  `acctauthentic` varchar(32) DEFAULT NULL,
  `connectinfo_start` varchar(50) DEFAULT NULL,
  `connectinfo_stop` varchar(50) DEFAULT NULL,
  `acctinputoctets` bigint(20) unsigned NOT NULL DEFAULT 0,
  `acctoutputoctets` bigint(20) unsigned NOT NULL DEFAULT 0,
  `calledstationid` varchar(50) NOT NULL DEFAULT '',
  `callingstationid` varchar(50) NOT NULL DEFAULT '',
  `acctterminatecause` varchar(32) NOT NULL DEFAULT '',
  `servicetype` varchar(32) DEFAULT NULL,
  `framedprotocol` varchar(32) DEFAULT NULL,
  `framedipaddress` varchar(15) NOT NULL DEFAULT '',
  `framedipv6address` varchar(45) NOT NULL DEFAULT '',
  `framedipv6prefix` varchar(45) NOT NULL DEFAULT '',
  `framedinterfaceid` varchar(44) NOT NULL DEFAULT '',
  `delegatedipv6prefix` varchar(45) NOT NULL DEFAULT '',
  PRIMARY KEY (`radacctid`, `acctstarttime`),
  UNIQUE KEY `acctuniqueid` (`acctuniqueid`, `acctstarttime`),
  KEY `username` (`username`),
  KEY `framedipaddress` (`framedipaddress`),
  KEY `acctsessionid` (`acctsessionid`),
  KEY `acctstarttime` (`acctstarttime`),
  KEY `acctstoptime` (`acctstoptime`),
  KEY `nasipaddress` (`nasipaddress`),
  KEY `idx_radacct_user_start` (`username`, `acctstarttime`),
  KEY `idx_radacct_nas_start` (`nasipaddress`, `acctstarttime`),
  KEY `idx_radacct_active` (`username`, `acctstoptime`),
  KEY `idx_radacct_stop` (`acctuniqueid`, `acctstoptime`),
  KEY `idx_radacct_nas_active` (`nasipaddress`, `acctstoptime`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
-- -----------------------------------------------------------------------------
-- Monthly range partitioning on acctstarttime.
--
-- 12 initial partitions covering 2026-04 .. 2027-03 (current month is
-- 2026-04-10), plus a p_future MAXVALUE catch-all so inserts never fail if
-- ops forgets to roll partitions forward. Rotate monthly via:
--   ALTER TABLE radacct REORGANIZE PARTITION p_future INTO (
--     PARTITION p2027_04 VALUES LESS THAN (TO_DAYS('2027-05-01')),
--     PARTITION p_future VALUES LESS THAN MAXVALUE
--   );
-- and archive old months with:
--   ALTER TABLE radacct DROP PARTITION p2026_04;
--
-- If you are running a tiny deployment (<< 1M radacct rows) and would rather
-- skip partition maintenance, delete this PARTITION BY clause -- the table
-- will still function identically, you just lose cheap archival.
-- -----------------------------------------------------------------------------
PARTITION BY RANGE (TO_DAYS(`acctstarttime`)) (
  PARTITION p2026_04 VALUES LESS THAN (TO_DAYS('2026-05-01')),
  PARTITION p2026_05 VALUES LESS THAN (TO_DAYS('2026-06-01')),
  PARTITION p2026_06 VALUES LESS THAN (TO_DAYS('2026-07-01')),
  PARTITION p2026_07 VALUES LESS THAN (TO_DAYS('2026-08-01')),
  PARTITION p2026_08 VALUES LESS THAN (TO_DAYS('2026-09-01')),
  PARTITION p2026_09 VALUES LESS THAN (TO_DAYS('2026-10-01')),
  PARTITION p2026_10 VALUES LESS THAN (TO_DAYS('2026-11-01')),
  PARTITION p2026_11 VALUES LESS THAN (TO_DAYS('2026-12-01')),
  PARTITION p2026_12 VALUES LESS THAN (TO_DAYS('2027-01-01')),
  PARTITION p2027_01 VALUES LESS THAN (TO_DAYS('2027-02-01')),
  PARTITION p2027_02 VALUES LESS THAN (TO_DAYS('2027-03-01')),
  PARTITION p2027_03 VALUES LESS THAN (TO_DAYS('2027-04-01')),
  PARTITION p_future VALUES LESS THAN MAXVALUE
);

CREATE TABLE IF NOT EXISTS `nas` (
  `id` int(10) NOT NULL AUTO_INCREMENT,
  `nasname` varchar(128) NOT NULL,
  `shortname` varchar(32) DEFAULT NULL,
  `type` varchar(30) DEFAULT 'other',
  `ports` int(5) DEFAULT NULL,
  `secret` varchar(60) NOT NULL DEFAULT 'secret',
  `server` varchar(64) DEFAULT NULL,
  `community` varchar(50) DEFAULT NULL,
  `description` varchar(200) DEFAULT 'RADIUS Client',
  PRIMARY KEY (`id`),
  KEY `nasname` (`nasname`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `radpostauth` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `username` varchar(64) NOT NULL DEFAULT '',
  `pass` varchar(64) NOT NULL DEFAULT '',
  `reply` varchar(32) NOT NULL DEFAULT '',
  `authdate` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `username` (`username`(32)),
  KEY `authdate` (`authdate`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
