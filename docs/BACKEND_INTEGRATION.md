# Backend ↔ RADIUS Integration Guide

> **Audience:** the Laravel/Octane backend (the `ebillio` repo) that provisions subscribers, bills them, and manages their sessions. This document is the complete contract between the backend and the FreeRADIUS stack in the `ebillio-radius` repo.
>
> **This is the file to paste into the backend Claude session.**

---

## 1. Where the RADIUS stack lives

Same host, same Docker daemon as the backend. The `radius-server` container runs in **host network mode** — it binds all its ports directly on the host, no port mapping.

| Port | Proto | Purpose | Who sends |
|---|---|---|---|
| `1812` | UDP | RADIUS Access-Request (authentication) | NAS devices (MikroTik, Cisco, etc.) |
| `1813` | UDP | RADIUS Accounting-Request (session start/stop/interim) | NAS devices |
| `1700` | UDP | CoA / Disconnect-Request — MikroTik default port | **The backend** (to kick / throttle subscribers) |
| `3799` | UDP | CoA / Disconnect-Request — IANA standard (Cisco, Juniper, etc.) | The backend |
| `18121` | UDP | Status-Server (health probes, Prometheus metrics) | Prometheus exporter (already running) |

**The backend does NOT send Access-Request packets.** Authentication is between the NAS and FreeRADIUS. The backend's role is (a) provisioning subscribers in the database and (b) sending CoA/Disconnect packets to NAS devices when billing state changes.

---

## 2. Shared MySQL database

Both projects talk to the **same** `ebillio-mysql` container. There's no second MySQL. They use different database users:

| User | Used by | Grants |
|---|---|---|
| `dasano` | **The backend** — Laravel code | Full grants on the `radius` database, plus all its own tables |
| `radius` | **FreeRADIUS** — internal only | `SELECT` on policy tables, `SELECT/INSERT/UPDATE/DELETE` on `radacct`, `INSERT` only on `radpostauth` |

The backend keeps using its existing `dasano` connection. **No changes needed on the backend's MySQL config** — it already has full access to the `radius` database.

Database: `radius`  
Host: `127.0.0.1:3306` (same as everything else the backend connects to)

---

## 3. Tables the backend writes to

All of these are in the `radius` database. The backend connects as `dasano`.

### 3.1 `radcheck` — user credentials + per-user auth rules

One row per attribute. Every subscriber needs **at least two rows** to be authentication-ready:

```sql
-- The password (required)
INSERT INTO radcheck (username, attribute, op, value)
VALUES (?, 'Cleartext-Password', ':=', ?);

-- The device limit (required for Simultaneous-Use enforcement to fire)
INSERT INTO radcheck (username, attribute, op, value)
VALUES (?, 'Simultaneous-Use', ':=', '1');
```

**Important:** if you skip the `Simultaneous-Use` row, FreeRADIUS will NOT enforce single-device login for that user — they can share credentials freely. `Simultaneous-Use := 1` is the sane default for residential plans. Multi-device plans use `:= 2`, `:= 3`, etc.

**To block a subscriber** (payment expired, service suspended):
```sql
-- Option A: soft block — keep password, add a reject rule
INSERT INTO radcheck (username, attribute, op, value)
VALUES (?, 'Auth-Type', ':=', 'Reject');

-- Option B: hard delete — wipes all radcheck rows for the user
DELETE FROM radcheck WHERE username = ?;
```

To **un-block** an `Auth-Type := Reject` user:
```sql
DELETE FROM radcheck
WHERE username = ? AND attribute = 'Auth-Type' AND value = 'Reject';
```

### 3.2 `radusergroup` — map a user to a policy group

Groups let you set plan-wide bandwidth/policy without duplicating per-user. Example: assign `alice` to the `gold_10mbps` group.

```sql
INSERT INTO radusergroup (username, groupname, priority)
VALUES (?, ?, 1);
```

To change a subscriber's plan, update their group membership:
```sql
UPDATE radusergroup SET groupname = ? WHERE username = ?;
```

### 3.3 `radgroupreply` — per-plan policy (the Mikrotik-Rate-Limit rows)

Define each plan **once**, then assign subscribers to it via `radusergroup`.

```sql
-- Example: a 10 Mbps down / 10 Mbps up plan with no burst
INSERT INTO radgroupreply (groupname, attribute, op, value)
VALUES ('gold_10mbps', 'Mikrotik-Rate-Limit', ':=', '10M/10M');

-- Example: 20/20 plan with 30M burst for 10 seconds, priority 5
INSERT INTO radgroupreply (groupname, attribute, op, value)
VALUES ('gold_20mbps', 'Mikrotik-Rate-Limit', ':=',
        '20M/20M 30M/30M 20M/20M 10/10 5');
```

The `Mikrotik-Rate-Limit` format is: `rx-rate[/tx-rate] [rx-burst/tx-burst] [rx-burst-threshold/tx-burst-threshold] [rx-burst-time/tx-burst-time] [priority]`. From the **router's** viewpoint, `rx` = subscriber upload, `tx` = subscriber download.

You can also put a subscriber into a MikroTik firewall address-list (used for walled-garden / QoS tiers / CGNAT pools):

```sql
INSERT INTO radgroupreply (groupname, attribute, op, value)
VALUES ('suspended', 'Mikrotik-Address-List', ':=', 'walled_garden');
```

### 3.4 `nas` — NAS client list (optional, defaults to clients.conf file)

If you want to manage NAS devices from the DB instead of the static `clients.conf` file, insert rows here:

```sql
INSERT INTO nas (nasname, shortname, type, secret, description)
VALUES ('203.0.113.10', 'nbo-pop1', 'mikrotik', ?, 'Nairobi POP 1');
```

FreeRADIUS has `read_clients = yes` enabled in `mods-enabled/sql`, so rows in `nas` are picked up at server restart (HUP).

---

## 4. Tables the backend reads from (for billing / reporting)

### 4.1 `radacct` — session history

Every subscriber session (PPPoE connect → disconnect) creates one row. Columns you'll care about:

| Column | Meaning |
|---|---|
| `username` | subscriber login |
| `acctsessionid` | NAS-assigned session ID |
| `acctstarttime` | when the session started |
| `acctupdatetime` | last Interim-Update (usually every 5 min) |
| `acctstoptime` | NULL = session still open; a datetime = session closed |
| `acctsessiontime` | seconds the session lasted |
| `acctinputoctets` | bytes uploaded (by the subscriber) — `BIGINT UNSIGNED`, gigaword-safe |
| `acctoutputoctets` | bytes downloaded |
| `framedipaddress` | IP assigned to the subscriber |
| `nasipaddress` | which NAS handled the session |
| `callingstationid` | usually the subscriber's MAC |
| `acctterminatecause` | user-request, lost-carrier, nas-reboot, etc. |

**Billing query: monthly data usage for a subscriber**
```sql
SELECT
    SUM(acctinputoctets)  AS total_up_bytes,
    SUM(acctoutputoctets) AS total_down_bytes,
    SUM(acctinputoctets + acctoutputoctets) AS total_bytes,
    SUM(acctsessiontime)  AS total_seconds
FROM radacct
WHERE username       = ?
  AND acctstarttime >= DATE_FORMAT(NOW(), '%Y-%m-01');
```

**Currently-online query** (for a real-time dashboard):
```sql
SELECT username, framedipaddress, acctstarttime,
       acctinputoctets, acctoutputoctets
FROM radacct
WHERE acctstoptime IS NULL;
```

**Who is using this IP right now** (abuse / NAT debugging):
```sql
SELECT username, acctstarttime, nasipaddress
FROM radacct
WHERE framedipaddress = ?
  AND acctstoptime IS NULL;
```

**Important warning about open sessions:** a row with `acctstoptime IS NULL` might be a real active session OR a stale row from a NAS reboot. The stale-session cleanup cron (`scripts/cleanup-stale-sessions.sh`, runs every 5 min on the host) closes rows whose `acctupdatetime` is older than 15 minutes. Always trust `acctupdatetime`, not just `acctstoptime`.

### 4.2 `radpostauth` — authentication audit log

Every Access-Request lands here (Accept or Reject). Useful for:
- Showing a subscriber their recent login attempts
- Detecting brute force / credential stuffing
- Debugging "why can't I log in"

```sql
SELECT username, reply, authdate
FROM radpostauth
WHERE username = ?
ORDER BY authdate DESC
LIMIT 20;
```

`reply` will be `Access-Accept` or `Access-Reject`.

---

## 5. Real-time session control — CoA / Disconnect (the important part)

This is the single most important thing the backend can do with RADIUS: **change a subscriber's session state WHILE they're connected**, without making them reconnect. You need this for:

- Kicking a subscriber the instant their balance hits zero
- Bumping someone from the 10M plan to the 20M plan after an upgrade — they get the new speed immediately
- Pushing a non-payer into a walled-garden address list so they can only reach the payment portal
- Letting them back in after payment

### 5.1 The protocol

RFC 5176. The backend acts as a **Dynamic Authorization Client** and sends packets directly to the NAS device (MikroTik, not FreeRADIUS). The NAS receives the packet, looks up the session, applies the change, and sends back an ACK or NAK.

- **Destination:** the NAS device's IP address (e.g. `203.0.113.10`)
- **Port:** `1700/udp` for MikroTik, `3799/udp` for Cisco / Juniper / Huawei / Nokia
- **Protocol:** RADIUS Disconnect-Request (code 40) or CoA-Request (code 43)
- **Shared secret:** set per-NAS in MikroTik's `/radius` config under `/ip hotspot` or `/ppp secrets` — the backend stores it per-NAS in the DB
- **Required attribute:** `Message-Authenticator` — FreeRADIUS enforces it, so do the NAS devices usually. Most RADIUS client libraries add it automatically.

The backend must know two things per session to target it:
1. Which NAS the subscriber is connected to (`nasipaddress` from `radacct`)
2. The session identifier (`acctsessionid` from `radacct`, or `framedipaddress`, or `User-Name`)

### 5.2 How to send CoA from PHP (Laravel)

**Recommended library:** [dapphp/radius](https://packagist.org/packages/dapphp/radius) — well-maintained, supports CoA/Disconnect, Message-Authenticator, the whole Attribute-Value-Pair spec.

```bash
composer require dapphp/radius
```

**Example: disconnect a subscriber mid-session**

```php
use Dapphp\Radius\Radius;

public function disconnectSession(Session $session): bool
{
    $nas = $session->nas;                    // your NAS eloquent model
    $client = new Radius();
    $client
        ->setServer($nas->ip_address)         // e.g. '203.0.113.10'
        ->setAuthenticationPort(1700)         // MikroTik default for CoA
        ->setSecret($nas->coa_secret)         // stored per-NAS, NEVER equals the auth secret
        ->setDebug(false);

    $client->setAttribute(1,  $session->username);            // User-Name
    $client->setAttribute(44, $session->acct_session_id);      // Acct-Session-Id
    $client->setAttribute(4,  $session->nas_ip);               // NAS-IP-Address
    // Framed-IP-Address helps when the session ID is ambiguous
    $client->setAttribute(8,  $session->framed_ip);            // Framed-IP-Address

    $ok = $client->sendDisconnect();
    if (!$ok) {
        Log::warning('CoA disconnect failed', [
            'session' => $session->id,
            'error'   => $client->getErrorMessage(),
            'code'    => $client->getErrorCode(),
        ]);
        return false;
    }
    return true;  // NAS returned Disconnect-ACK
}
```

**Example: change a subscriber's bandwidth mid-session (plan upgrade)**

```php
public function changeRateLimit(Session $session, string $newLimit): bool
{
    $nas = $session->nas;
    $client = new Radius();
    $client
        ->setServer($nas->ip_address)
        ->setAuthenticationPort(1700)
        ->setSecret($nas->coa_secret);

    $client->setAttribute(1,  $session->username);
    $client->setAttribute(44, $session->acct_session_id);
    $client->setAttribute(4,  $session->nas_ip);

    // Mikrotik-Rate-Limit VSA: vendor 14988, type 8, value is a string
    $client->setVendorSpecificAttribute(14988, 8, $newLimit);  // e.g. "20M/20M"

    return $client->sendCoA();  // sends a CoA-Request, expects CoA-ACK
}
```

**Example: push a non-payer into the walled-garden address list**

```php
public function moveToWalledGarden(Session $session): bool
{
    $nas = $session->nas;
    $client = new Radius();
    $client
        ->setServer($nas->ip_address)
        ->setAuthenticationPort(1700)
        ->setSecret($nas->coa_secret);

    $client->setAttribute(1,  $session->username);
    $client->setAttribute(44, $session->acct_session_id);

    // Mikrotik-Address-List VSA: vendor 14988, type 19, value is a string
    $client->setVendorSpecificAttribute(14988, 19, 'walled_garden');

    return $client->sendCoA();
}
```

On the MikroTik side, the `walled_garden` firewall address-list must exist with mangle/filter rules that redirect traffic to the payment portal. That's a one-time router config, not a per-subscriber thing.

### 5.3 Error codes you'll see

When a CoA fails, check `$client->getErrorCode()`. RFC 5176 defines an `Error-Cause` attribute — the library surfaces it as:

| Code | Meaning | What it means for you |
|---|---|---|
| 503 | Session-Context-Not-Found | The session you tried to kick is already gone. Treat as success for disconnects, retry with fresh session data for CoA-Request. |
| 401 | Unsupported-Attribute | The NAS doesn't support an attribute you sent. MikroTik doesn't accept every CoA attribute — stick to User-Name, Acct-Session-Id, Framed-IP-Address, Mikrotik-Rate-Limit, Mikrotik-Address-List. |
| 403 | NAS-Identification-Mismatch | The `NAS-IP-Address` you sent doesn't match the NAS you're talking to. Check the NAS IP. |
| 404 | Invalid-Request | Malformed packet. Missing attribute, bad secret, missing Message-Authenticator. |
| 501 | Administratively-Prohibited | MikroTik's `/radius incoming` is disabled. Enable it: `/radius incoming set accept=yes port=1700`. |

### 5.4 Alternative: shell out to `radclient`

If you don't want the PHP library, `radclient` is installed inside the `radius-server` container and you can `exec` it from the backend:

```php
public function disconnectSessionViaRadclient(Session $session): bool
{
    $attrs = sprintf(
        "User-Name=%s,Acct-Session-Id=%s,NAS-IP-Address=%s,Message-Authenticator=0x00",
        escapeshellarg($session->username),
        escapeshellarg($session->acct_session_id),
        escapeshellarg($session->nas_ip)
    );
    $cmd = sprintf(
        'echo %s | docker exec -i radius-server radclient -x %s:1700 disconnect %s',
        escapeshellarg($attrs),
        escapeshellarg($session->nas->ip_address),
        escapeshellarg($session->nas->coa_secret)
    );
    $output = shell_exec($cmd);
    return str_contains($output ?? '', 'Disconnect-ACK');
}
```

This is slower (one process spawn per call) and doesn't surface Error-Cause cleanly, but it needs no new Composer dependency and works from any container that can reach Docker.

---

## 6. Required NAS config (one-time, on every MikroTik router)

For CoA to work, each MikroTik router must be told to **accept incoming CoA** from the backend's IP:

```
/radius incoming set accept=yes port=1700
/ip firewall filter add chain=input protocol=udp dst-port=1700 \
    src-address=<backend-public-ip> action=accept comment="eBillio CoA"
```

And the backend's IP must also be listed in the NAS's `/radius` client list (the same one the NAS uses to send Accounting-Requests to FreeRADIUS):

```
/radius add service=ppp,hotspot,login,wireless \
    address=<radius-server-ip> \
    secret=<the-radius-shared-secret> \
    accounting-port=1813 \
    authentication-port=1812 \
    timeout=3s \
    comment="eBillio RADIUS"
```

**Important:** `<the-radius-shared-secret>` is `RADIUS_SECRET` from the `ebillio-radius/.env` file — the one used for auth/acct traffic. The **CoA shared secret** (`COA_SECRET` in the same `.env`) is a **DIFFERENT** value that goes on the backend side only.

The separation is intentional: if a NAS is compromised, the attacker only gets the auth secret (they can impersonate a NAS to FreeRADIUS). They do NOT get the CoA secret (so they can't kick or throttle other subscribers).

---

## 7. What NOT to do

- **Don't** have the backend send Access-Request packets. That's the NAS's job.
- **Don't** reuse `RADIUS_SECRET` as the CoA secret. They must be different.
- **Don't** write to `radpostauth` from the backend. It's append-only audit data written by FreeRADIUS.
- **Don't** DELETE from `radacct` from the backend unless you're running a scheduled archival job. Active session rows live there and FreeRADIUS is UPDATE-ing them.
- **Don't** run raw `UPDATE` on `radacct` to close sessions. Send a Disconnect-Request to the NAS and let FreeRADIUS close the row via the normal accounting flow. The only exception is the stale-session cleanup cron, which is specifically for rows whose NAS stopped sending interim updates.
- **Don't** store `COA_SECRET` or `RADIUS_SECRET` in the database. Keep them in `.env` only.
- **Don't** assume `Framed-IP-Address` is unique — on CGNAT it's not, and you'll need `username` or `acctsessionid` as the primary session identifier.

---

## 8. Quick smoke test from the backend side

After wiring up the code, verify end-to-end:

```php
// 1. Create a test subscriber
DB::connection('radius')->table('radcheck')->insert([
    ['username' => 'smoketest', 'attribute' => 'Cleartext-Password', 'op' => ':=', 'value' => 'smoke123'],
    ['username' => 'smoketest', 'attribute' => 'Simultaneous-Use',   'op' => ':=', 'value' => '1'],
]);

// 2. Ask a real NAS to authenticate it (from the NAS side, not here)
//    /tool fetch address=<radius-server-ip> port=1812 ... etc — normally done by
//    the subscriber's router as part of PPPoE

// 3. Read the audit log from the backend
$result = DB::connection('radius')
    ->table('radpostauth')
    ->where('username', 'smoketest')
    ->latest('authdate')
    ->first();
// $result->reply should be 'Access-Accept'

// 4. Clean up
DB::connection('radius')->table('radcheck')->where('username', 'smoketest')->delete();
DB::connection('radius')->table('radpostauth')->where('username', 'smoketest')->delete();
```

---

## 9. Files on the RADIUS side you might want to read

| File | Why |
|---|---|
| `sql/setup-radius-on-shared-mysql.sql` | The exact grants + DDL that set up the shared `radius` DB and user |
| `sql/seed-test-data.sql` | Sample test users — useful as a template for real subscribers |
| `freeradius/default` | The `authorize` / `authenticate` / `accounting` / `session` pipeline |
| `freeradius/coa` | The CoA listener FreeRADIUS exposes — not what the backend talks to (the backend talks to the NAS directly), but useful if you want to understand inbound CoA too |
| `scripts/coa/disconnect-user.sh` + `change-bandwidth.sh` | Reference shell scripts showing the exact `radclient` invocations |
| `docs/SIMULTANEOUS_USE.md` | Deep dive on the Simultaneous-Use enforcement and the provisioning code changes needed in the backend |

---

## 10. TL;DR — what to ask the backend AI to build

1. **A `Nas` Eloquent model** with columns `id`, `name`, `ip_address`, `shared_secret`, `coa_secret`, `coa_port` (default 1700), `kind` (mikrotik/cisco/etc.).
2. **A `RadiusUser` service** that wraps `radcheck` / `radusergroup` inserts/updates/deletes for subscriber provisioning. Always inserts both `Cleartext-Password` and `Simultaneous-Use` rows on create.
3. **A `CoaClient` service** using `dapphp/radius` that exposes `disconnect($session)`, `changeRateLimit($session, $newLimit)`, `moveToWalledGarden($session)`, and `releaseFromWalledGarden($session)`. Pulls per-NAS `coa_secret` from the `Nas` model.
4. **A `SessionQuery` service** that wraps `radacct` reads: `active()`, `forUser($u)`, `bytesThisMonth($u)`, `lastFor($u)`, etc.
5. **A payment hook** — when a subscription expires or a top-up runs out, call `CoaClient::moveToWalledGarden()` on the subscriber's active session. When payment lands, call `releaseFromWalledGarden()` (or send a `CoA-Request` removing the `Mikrotik-Address-List` attribute).
6. **An admin UI** for managing NAS devices and plans (`radgroupreply` rows).
7. **A scheduled Artisan command** that reads `radacct` daily and writes summary rows into the backend's own billing tables. Do NOT query `radacct` on every page load.
