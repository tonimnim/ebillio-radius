# Simultaneous-Use Enforcement

## What this is

A `Simultaneous-Use` check attribute on a subscriber tells FreeRADIUS to count how many of that subscriber's accounting sessions are currently open in `radacct` (i.e. `acctstoptime IS NULL`) before allowing a new login. If the count would exceed the limit, the new Access-Request is rejected.

This is the standard way ISPs prevent **credential resale** — one customer paying for service and then sharing the username/password with friends, family, or selling it on. It is the single biggest source of revenue leakage in residential ISP billing.

## How eBillio is configured

`freeradius/default` already has the `session { sql }` block enabled (added in `feature/hardening-pass-1`). FreeRADIUS will only **fire** that block if the user has a `Simultaneous-Use` row in `radcheck`. Without that row, the block is dead code and account sharing is unrestricted.

The default setting should be `Simultaneous-Use := 1` (one device per credential). Premium plans can override per-user with `:= 2`, `:= 3`, etc.

## Backfill for existing subscribers

Run the migration once against your production database:

```bash
docker exec -i radius-mysql mysql -uroot -p"$DB_ROOT_PASSWORD" radius \
    < sql/migrations/002_backfill_simultaneous_use.sql
```

It is **idempotent** — safe to re-run, won't double-insert, won't touch users who already have a custom value.

## Provisioning new subscribers (Railway billing app code change)

The Railway-hosted billing web app provisions new subscribers by writing rows into the `radcheck` table on the eBillio MySQL instance. **You must update the provisioning code** so every new subscriber gets a `Simultaneous-Use` row inserted alongside the password row.

### Pattern (pseudo-SQL — adapt to your ORM)

When creating a new subscriber, insert **two** rows into `radcheck`:

```sql
INSERT INTO radcheck (username, attribute, op, value) VALUES
  (:username, 'Cleartext-Password', ':=', :password),
  (:username, 'Simultaneous-Use',   ':=', '1');
```

If your ORM is one row at a time, just call insert twice in the same transaction.

### Per-plan limits

If your billing platform sells plans with different concurrent-device limits (e.g. "Family plan: 4 devices"), make the second insert configurable:

```sql
INSERT INTO radcheck (username, attribute, op, value) VALUES
  (:username, 'Simultaneous-Use', ':=', :max_devices);
```

Where `:max_devices` comes from the plan record. Default to `1` for any plan that doesn't specify.

### Updating an existing subscriber's plan

If a subscriber upgrades to a multi-device plan, **UPDATE** their existing `Simultaneous-Use` row rather than inserting a new one:

```sql
UPDATE radcheck
SET value = :new_max_devices
WHERE username = :username
  AND attribute = 'Simultaneous-Use';
```

### Deleting a subscriber

When you remove a subscriber, delete *all* their `radcheck` rows (the password row AND the Simultaneous-Use row), not just one of them:

```sql
DELETE FROM radcheck WHERE username = :username;
```

## Operational dependency

Simultaneous-Use checks count rows in `radacct` where `acctstoptime IS NULL`. If a NAS reboots without sending Accounting-Stop, those rows stay open forever and the legitimate subscriber gets locked out as "already logged in."

`scripts/cleanup-stale-sessions.sh` closes those zombie rows. **You must install it as a cron job** (every 5 minutes is the documented cadence) on the Docker host. See `scripts/install-cron.sh` for the installer or `docs/CRON.md` for the manual instructions.

Without that cron, Simultaneous-Use will lock users out a few hours after the first NAS reboot. **Do not enable Simultaneous-Use without also installing the cleanup cron.**

## Verification

After running the backfill:

```sql
-- Should return 0 (every username has a Simultaneous-Use row)
SELECT COUNT(DISTINCT username) FROM radcheck
WHERE username NOT IN (
  SELECT DISTINCT username FROM radcheck WHERE attribute='Simultaneous-Use'
);

-- Should match COUNT(DISTINCT username)
SELECT COUNT(*) FROM radcheck WHERE attribute='Simultaneous-Use';
```

After deploying the provisioning code change, create a test subscriber via the Railway app and verify both rows appear:

```sql
SELECT * FROM radcheck WHERE username = 'test-new-subscriber';
```

## What to monitor

- **Metric:** `mysql_global_status_questions{tableName="radcheck"}` — checks should rise after the backfill (every Access-Request now counts radacct open sessions).
- **Alert:** spike in Access-Reject rate after deploy could indicate either successful enforcement (good — but communicate to support) or false rejections from stale `radacct` rows (bad — verify cleanup cron is running).
- **Log pattern to grep for:** `Multiple logins (max 1) - Rejected` in `radius.log`. Legitimate enforcement looks like this; sudden spikes need investigation.
