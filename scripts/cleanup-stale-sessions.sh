#!/usr/bin/env bash
# =============================================================================
# cleanup-stale-sessions.sh — eBillio RADIUS stale-session closer
# =============================================================================
#
# WHAT
#   Closes `radacct` rows whose Interim-Update is older than 15 minutes.
#   Synthesizes a stop time and a NAS-Reboot terminate cause. See
#   sql/maintenance.sql (Query 1) for the exact UPDATE.
#
# WHY
#   FreeRADIUS's session{} block (freeradius/default) checks `radacct` for
#   open sessions to enforce Simultaneous-Use := 1. When a NAS reboots
#   without sending Accounting-Stop, the row stays open forever and the
#   legitimate user gets rejected as "already logged in" on their next
#   auth. *** Without this cron job running, Simultaneous-Use will lock
#   users out after the first NAS reboot. *** Treat this script as
#   load-bearing for the subscriber login path.
#
#   On Accounting-On (NAS boot notification), FreeRADIUS already closes
#   that NAS's open sessions itself because `accounting { sql }` is
#   wired in freeradius/default — the sql module's accounting_onoff_query
#   runs automatically. This script is the fallback for NAS devices that
#   crash without sending Accounting-On (power loss, kernel panic, etc.).
#
# SCHEDULE
#   Run every 5 minutes via cron on the Docker host:
#     */5 * * * * /path/to/cleanup-stale-sessions.sh >> /var/log/radius-cleanup.log 2>&1
#
#   (A host crontab entry is preferred over an in-compose cron sidecar to
#   keep the stack minimal. See README / docker-compose.yml.)
#
# ENVIRONMENT
#   DB_USERNAME        FreeRADIUS app user (default: radius). Must have
#                      UPDATE on radacct — sql/restrict-privileges.sql
#                      grants this, so the default `radius` user is fine.
#   DB_PASSWORD        Password for the DB_USERNAME account. Read from .env.
#   MYSQL_CONTAINER    Docker container name (default: ebillio-mysql).
#                      This is the SHARED eBillio backend MySQL container,
#                      not a dedicated radius-mysql.
#   MYSQL_DATABASE     Database name (default: radius)
#
#   NOTE on root: this script does NOT use DB_ROOT_PASSWORD anymore. The
#   shared ebillio-mysql container has its OWN root password (managed by
#   the backend stack) which is different from our DB_ROOT_PASSWORD. The
#   dedicated `radius` user has exactly the privileges needed for this
#   cleanup (UPDATE on radacct) — see sql/restrict-privileges.sql.
#
#   The script sources `.env` next to docker-compose.yml if present.
# =============================================================================

set -euo pipefail

# Resolve script and project directories (project = parent of scripts/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load .env if present (without leaking to child processes beyond what we need)
if [[ -f "${PROJECT_DIR}/.env" ]]; then
    # shellcheck disable=SC1091
    set -a
    . "${PROJECT_DIR}/.env"
    set +a
fi

MYSQL_CONTAINER="${MYSQL_CONTAINER:-ebillio-mysql}"
MYSQL_DATABASE="${MYSQL_DATABASE:-radius}"
DB_USERNAME="${DB_USERNAME:-radius}"

# Use the dedicated RADIUS app user. Its grants (UPDATE on radacct)
# cover exactly what this script needs. See sql/restrict-privileges.sql.
if [[ -z "${DB_PASSWORD:-}" ]]; then
    echo "[$(date -Is)] ERROR: DB_PASSWORD is not set in ${PROJECT_DIR}/.env" >&2
    exit 1
fi
MYSQL_USER="${DB_USERNAME}"
MYSQL_PASS="${DB_PASSWORD}"

# Verify the mysql container is up before trying to exec into it.
if ! docker inspect -f '{{.State.Running}}' "${MYSQL_CONTAINER}" 2>/dev/null | grep -q true; then
    echo "[$(date -Is)] ERROR: container '${MYSQL_CONTAINER}' is not running" >&2
    exit 1
fi

# The UPDATE statement. Kept in-sync with sql/maintenance.sql Query 1.
# ROW_COUNT() after the UPDATE returns the number of sessions closed.
SQL=$(cat <<'EOSQL'
UPDATE radacct
SET acctstoptime = DATE_ADD(acctupdatetime, INTERVAL 300 SECOND),
    acctterminatecause = 'NAS-Reboot',
    acctsessiontime = TIMESTAMPDIFF(SECOND, acctstarttime, acctupdatetime)
WHERE acctstoptime IS NULL
  AND acctupdatetime < NOW() - INTERVAL 15 MINUTE;
SELECT ROW_COUNT() AS closed;
EOSQL
)

# Pass the password via MYSQL_PWD env var to avoid it showing up in `ps`.
# -N -B: no column names, tab-separated — easy to parse.
OUTPUT=$(
    docker exec -i \
        -e MYSQL_PWD="${MYSQL_PASS}" \
        "${MYSQL_CONTAINER}" \
        mysql -u "${MYSQL_USER}" -N -B "${MYSQL_DATABASE}" <<<"${SQL}"
)

# Last line of mysql -N -B output is the ROW_COUNT result.
CLOSED=$(printf '%s\n' "${OUTPUT}" | tail -n 1 | tr -d '[:space:]')
: "${CLOSED:=0}"

echo "[$(date -Is)] cleanup-stale-sessions: closed ${CLOSED} stale radacct row(s)"
