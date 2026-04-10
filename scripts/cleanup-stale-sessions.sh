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
#   DB_ROOT_PASSWORD   MySQL root password (preferred — UPDATE on radacct)
#   DB_PASSWORD        Fallback: the FreeRADIUS app user's password, if it
#                      has UPDATE on radacct (it does in the default schema).
#   DB_USERNAME        FreeRADIUS app user (default: radius)
#   MYSQL_CONTAINER    Docker container name (default: radius-mysql)
#   MYSQL_DATABASE     Database name (default: radius)
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

MYSQL_CONTAINER="${MYSQL_CONTAINER:-radius-mysql}"
MYSQL_DATABASE="${MYSQL_DATABASE:-radius}"
DB_USERNAME="${DB_USERNAME:-radius}"

# Prefer root (guaranteed UPDATE privs); fall back to the app user.
if [[ -n "${DB_ROOT_PASSWORD:-}" ]]; then
    MYSQL_USER="root"
    MYSQL_PASS="${DB_ROOT_PASSWORD}"
elif [[ -n "${DB_PASSWORD:-}" ]]; then
    MYSQL_USER="${DB_USERNAME}"
    MYSQL_PASS="${DB_PASSWORD}"
else
    echo "[$(date -Is)] ERROR: neither DB_ROOT_PASSWORD nor DB_PASSWORD is set" >&2
    exit 1
fi

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
