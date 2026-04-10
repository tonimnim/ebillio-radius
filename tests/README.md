# eBillio RADIUS  --  test harness

End-to-end tests that exercise the live docker-compose stack via `radclient`
and direct SQL queries. Purpose: give you one command to run after a code
change that answers "does auth still work, does accounting still land in
the database, does CoA still function?".

## Prerequisites

1. Docker + `docker compose` plugin installed on the host.
2. `.env` file populated at the repo root (copied from `.env.example`):
   - `RADIUS_SECRET`
   - `DB_ROOT_PASSWORD`
   - `DB_USERNAME`
   - `DB_PASSWORD`
3. The stack must be running:
   ```bash
   make up
   ```
4. Test data must be seeded:
   ```bash
   make seed
   ```

You do **not** need `radclient` or `mysql` on the host. All tests execute
`radclient` inside the `radius-server` container and `mysql` inside the
`radius-mysql` container via `docker exec`. The only host-side requirements
are `bash`, `docker`, `sed`, `awk`, and `grep`.

## Quick start

```bash
make up            # start the stack
make seed          # insert test users, group, NAS
make test          # run auth + accounting + coa
make clean-test-data   # (optional) wipe the seeded rows
```

Or as a one-liner after `make up`:

```bash
make seed && make test
```

To clean up automatically after the run:

```bash
tests/run-all.sh --clean
```

## What each test covers

### `tests/test-auth.sh`

| Case                                                       | Expect        |
|------------------------------------------------------------|---------------|
| PAP auth of `testuser-pap` with correct password           | Access-Accept |
| The Accept carries `Mikrotik-Rate-Limit = 10M/10M`         | present       |
| PAP auth of `testuser-pap` with wrong password             | Access-Reject |
| Auth of `testuser-blocked` (Auth-Type := Reject)           | Access-Reject |
| CHAP auth of `testuser-chap` with correct password         | Access-Accept |

Covers: the `authorize` and `authenticate` sections of `sites-enabled/default`,
the SQL module's read of `radcheck`, `radusergroup`, `radgroupreply`, and the
PAP + CHAP authenticators.

Does **not** cover: EAP (PEAP/TTLS/TLS), MS-CHAPv2, RadSec, proxying,
multi-realm routing, client-by-IP enforcement from `clients.conf` subnets
beyond 127.0.0.1.

### `tests/test-accounting.sh`

Walks a fake session through the full lifecycle:

1. `Acct-Status-Type = Start` -> row appears in `radacct` with
   `acctstarttime` set and `acctstoptime` NULL.
2. `Acct-Status-Type = Interim-Update` with octet counters -> `acctupdatetime`
   and the `acctinputoctets` / `acctoutputoctets` columns advance.
3. `Acct-Status-Type = Stop` with `Acct-Terminate-Cause = User-Request` ->
   `acctstoptime` is set and the terminate cause is recorded.

Each test run uses a unique `Acct-Session-Id` of the form
`test-<epoch>-<pid>`. The trap in the script deletes the row on exit
regardless of pass/fail, so re-runs stay clean.

Covers: the `preacct` and `accounting` sections, the SQL accounting queries,
the `radacct` table schema.

Does **not** cover: `Alive` packets specifically (Interim-Update is the same
packet type in practice), Acct-Off / Acct-On NAS reboot handling, accounting
proxying.

### `tests/test-coa.sh`

Smoke test for Change-of-Authorization / Disconnect-Message. **Depends on
another agent's CoA work** (expected: a `sites-enabled/coa` with a
`listen { type = coa port = 3799 }` stanza, a `COA_SECRET` env var, and UDP
3799 either exposed on the host or at least reachable from inside the
`radius-server` container).

Behaviour:
- Auto-detects whether a CoA listener is running (checks `ss -lnu` inside
  the container, then falls back to grepping `sites-enabled/` for
  `type = coa`).
- If not detected, prints `SKIPPED` and exits 0. The full test suite will
  still pass.
- If detected, it inserts a fake live row into `radacct`, sends a
  Disconnect-Request, and expects a Disconnect-ACK. Row closure is
  best-effort (no real NAS is there to handle the disconnect).

Does **not** cover: full CoA-Request attribute rewriting, NAS vendor
dictionaries beyond the defaults, authorization of the CoA client by IP.

## Adding new test cases

Every test script follows the same shape:

```bash
echo "[N] description of the case"
out=$(printf 'User-Name = "..."\nUser-Password = "..."\n' | rc auth 2>&1 || true)
if grep -q 'Received Access-Accept' <<<"${out}"; then
    ok "what you expected"
else
    bad "what was wrong"
    printf '%s\n' "${out}" | sed 's/^/        /'
fi
```

The helpers `ok` / `bad` increment `PASS` / `FAIL`; the script exits 1 at
the end if any case failed. The `rc` helper pipes an attribute block into
`radclient` inside the `radius-server` container. When you add a case:

1. Prefix any new user with `testuser-` so `sql/clean-test-data.sql` sweeps
   it up.
2. If the case needs new seed rows, add them to `sql/seed-test-data.sql`
   (and the matching DELETE to `sql/clean-test-data.sql`).
3. Quote string attribute values with `"..."` inside the attribute block.
   radclient is strict about unquoted strings with spaces.

## Known limitations

- **No EAP testing.** `eapol_test` from wpa_supplicant is required for
  full PEAP/TTLS/TLS verification and is not installed in the FreeRADIUS
  image. The harness verifies only PAP and CHAP (and Auth-Type := Reject).
- **No RadSec testing.** RadSec (RADIUS over TLS/TCP) is not enabled in
  this stack.
- **CoA is smoke-level only.** The CoA test proves the listener is
  reachable and returns an ACK; it does not verify that a real NAS applies
  the disconnect. Full verification requires an actual router in the loop.
- **No MS-CHAPv2.** The `mschap` module is referenced in `sites-enabled/default`
  but the test harness does not drive it; radclient cannot compute an
  MS-CHAPv2 response on its own.
- **Single client IP.** All tests talk to FreeRADIUS from 127.0.0.1 (inside
  the container). Multi-NAS auth policies cannot be exercised from here.
- **No load testing.** The harness is correctness-only. For load use
  `radclient` with `-p` (parallel) separately, or a tool like
  `radperf` / `freeradius-utils`.

## Troubleshooting

| Symptom                                                   | Likely cause                                                                 |
|-----------------------------------------------------------|------------------------------------------------------------------------------|
| `container radius-server is not running`                  | You forgot `make up`.                                                        |
| `No reply from server` in test-auth                       | `RADIUS_SECRET` in `.env` does not match the seeded NAS row. Re-run `make seed` after editing `.env`. |
| `Access-Reject` where `Access-Accept` was expected        | Test data was not seeded. Run `make seed`.                                   |
| `ERROR 1045 Access denied` from mysql                     | `DB_ROOT_PASSWORD` in `.env` does not match the running container. The password is baked in on first `docker compose up`; to change it you must `docker compose down -v` (destroys data). |
| `test-accounting.sh` finds 0 radacct rows after Start     | The NAS entry in the `nas` table does not match the secret, or `read_clients = yes` did not load the row. Check `docker compose logs freeradius`. |
| `test-coa.sh` always SKIPPED                              | Expected  --  the CoA listener is not yet enabled.                           |

## File layout

```
sql/
  seed-test-data.sql     # INSERT rows, prefixed testuser-/testgroup-
  clean-test-data.sql    # DELETE rows, scoped by the same prefixes
tests/
  test-auth.sh           # radclient auth tests
  test-accounting.sh     # radclient accounting lifecycle + mysql assertions
  test-coa.sh            # CoA smoke test (skips if listener absent)
  run-all.sh             # runs everything, totals pass/fail, optional --clean
  README.md              # this file
Makefile                 # make up / seed / test / clean-test-data / etc.
```
