#!/usr/bin/env bash
# ============================================================================
# test-accounting.sh  --  radclient-driven accounting lifecycle test
#
# Walks a fake session through Start -> Interim-Update -> Stop and verifies
# each step lands in radacct correctly:
#   1. Start inserts a row (acctstarttime set, acctstoptime NULL)
#   2. Interim-Update advances acctupdatetime and the octet counters
#   3. Stop sets acctstoptime and acctterminatecause
#
# The test row is deleted at the end regardless of pass/fail (trap EXIT).
#
# All MySQL access is done via `docker exec radius-mysql mysql` so the host
# does not need a mysql client. All radclient calls run inside radius-server
# so the host does not need radclient either.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -z "${RADIUS_SECRET:-}" || -z "${DB_ROOT_PASSWORD:-}" ]]; then
    if [[ -f "${REPO_ROOT}/.env" ]]; then
        # shellcheck disable=SC1091
        set -a; . "${REPO_ROOT}/.env"; set +a
    fi
fi

: "${RADIUS_SECRET:?RADIUS_SECRET is not set}"
: "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD is not set}"

RADIUS_CONTAINER="${RADIUS_CONTAINER:-radius-server}"
MYSQL_CONTAINER="${MYSQL_CONTAINER:-radius-mysql}"
RADIUS_HOST="${RADIUS_HOST:-127.0.0.1}"
RADIUS_ACCT_PORT="${RADIUS_ACCT_PORT:-1813}"

# Unique session id for this run so parallel runs do not collide.
SESSION_ID="test-$(date +%s)-$$"
ACCT_USER="testuser-pap"

PASS=0
FAIL=0

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

ok()  { green "  PASS  $*"; PASS=$((PASS+1)); }
bad() { red   "  FAIL  $*"; FAIL=$((FAIL+1)); }

cleanup() {
    # Always attempt to remove the row so re-runs stay clean.
    docker exec -i "${MYSQL_CONTAINER}" \
        mysql -uroot -p"${DB_ROOT_PASSWORD}" radius \
        -e "DELETE FROM radacct WHERE acctsessionid='${SESSION_ID}';" \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---- helpers ---------------------------------------------------------------

# Run an SQL query that returns a single scalar; prints the value.
sql_scalar() {
    local q="$1"
    docker exec -i "${MYSQL_CONTAINER}" \
        mysql -N -B -uroot -p"${DB_ROOT_PASSWORD}" radius -e "${q}" 2>/dev/null
}

# Send an accounting packet. Attribute block comes from stdin.
rc_acct() {
    docker exec -i "${RADIUS_CONTAINER}" \
        radclient -x -r 1 -t 3 \
            "${RADIUS_HOST}:${RADIUS_ACCT_PORT}" acct "${RADIUS_SECRET}"
}

# ---- preflight -------------------------------------------------------------
if ! docker ps --format '{{.Names}}' | grep -qx "${RADIUS_CONTAINER}"; then
    red "FAIL: container ${RADIUS_CONTAINER} is not running. Run 'make up' first."
    exit 2
fi
if ! docker ps --format '{{.Names}}' | grep -qx "${MYSQL_CONTAINER}"; then
    red "FAIL: container ${MYSQL_CONTAINER} is not running. Run 'make up' first."
    exit 2
fi

echo
yellow "=== test-accounting.sh  (session ${SESSION_ID}) ==="
echo

# ---------------------------------------------------------------------------
# Step 1: Accounting-Start
# ---------------------------------------------------------------------------
echo "[1] Accounting-Start"
start_pkt=$(cat <<EOF
User-Name = "${ACCT_USER}"
Acct-Status-Type = Start
Acct-Session-Id = "${SESSION_ID}"
NAS-IP-Address = 127.0.0.1
NAS-Port = 0
NAS-Port-Type = Ethernet
Framed-IP-Address = 10.99.0.99
Acct-Authentic = RADIUS
Calling-Station-Id = "AA:BB:CC:DD:EE:FF"
Called-Station-Id  = "11:22:33:44:55:66"
EOF
)
out=$(printf '%s\n' "${start_pkt}" | rc_acct 2>&1 || true)
if grep -q 'Received Accounting-Response' <<<"${out}"; then
    ok "Accounting-Response received"
else
    bad "No Accounting-Response to Start:"
    printf '%s\n' "${out}" | sed 's/^/        /'
fi

row=$(sql_scalar "SELECT COUNT(*) FROM radacct WHERE acctsessionid='${SESSION_ID}';")
if [[ "${row}" == "1" ]]; then
    ok "radacct row created"
else
    bad "Expected 1 radacct row, found '${row}'"
fi

start_time=$(sql_scalar "SELECT acctstarttime FROM radacct WHERE acctsessionid='${SESSION_ID}';")
if [[ -n "${start_time}" && "${start_time}" != "NULL" ]]; then
    ok "acctstarttime set: ${start_time}"
else
    bad "acctstarttime is NULL after Start"
fi

# ---------------------------------------------------------------------------
# Step 2: Accounting Interim-Update  --  verify counters advance
# ---------------------------------------------------------------------------
# Sleep 1s so acctupdatetime strictly advances past acctstarttime.
sleep 1

echo "[2] Accounting Interim-Update"
interim_pkt=$(cat <<EOF
User-Name = "${ACCT_USER}"
Acct-Status-Type = Interim-Update
Acct-Session-Id = "${SESSION_ID}"
NAS-IP-Address = 127.0.0.1
NAS-Port = 0
Framed-IP-Address = 10.99.0.99
Acct-Session-Time = 30
Acct-Input-Octets  = 123456
Acct-Output-Octets = 654321
EOF
)
out=$(printf '%s\n' "${interim_pkt}" | rc_acct 2>&1 || true)
if grep -q 'Received Accounting-Response' <<<"${out}"; then
    ok "Accounting-Response received"
else
    bad "No Accounting-Response to Interim-Update"
    printf '%s\n' "${out}" | sed 's/^/        /'
fi

in_octets=$(sql_scalar  "SELECT acctinputoctets  FROM radacct WHERE acctsessionid='${SESSION_ID}';")
out_octets=$(sql_scalar "SELECT acctoutputoctets FROM radacct WHERE acctsessionid='${SESSION_ID}';")
if [[ "${in_octets}" == "123456" && "${out_octets}" == "654321" ]]; then
    ok "Octet counters match (in=${in_octets} out=${out_octets})"
else
    bad "Octet counters wrong (in=${in_octets} out=${out_octets}, expected 123456/654321)"
fi

update_time=$(sql_scalar "SELECT acctupdatetime FROM radacct WHERE acctsessionid='${SESSION_ID}';")
if [[ -n "${update_time}" && "${update_time}" != "NULL" ]]; then
    ok "acctupdatetime set: ${update_time}"
else
    bad "acctupdatetime is NULL after Interim-Update"
fi

# ---------------------------------------------------------------------------
# Step 3: Accounting-Stop
# ---------------------------------------------------------------------------
sleep 1

echo "[3] Accounting-Stop"
stop_pkt=$(cat <<EOF
User-Name = "${ACCT_USER}"
Acct-Status-Type = Stop
Acct-Session-Id = "${SESSION_ID}"
NAS-IP-Address = 127.0.0.1
NAS-Port = 0
Framed-IP-Address = 10.99.0.99
Acct-Session-Time   = 60
Acct-Input-Octets   = 200000
Acct-Output-Octets  = 800000
Acct-Terminate-Cause = User-Request
EOF
)
out=$(printf '%s\n' "${stop_pkt}" | rc_acct 2>&1 || true)
if grep -q 'Received Accounting-Response' <<<"${out}"; then
    ok "Accounting-Response received"
else
    bad "No Accounting-Response to Stop"
    printf '%s\n' "${out}" | sed 's/^/        /'
fi

stop_time=$(sql_scalar "SELECT acctstoptime FROM radacct WHERE acctsessionid='${SESSION_ID}';")
if [[ -n "${stop_time}" && "${stop_time}" != "NULL" ]]; then
    ok "acctstoptime set: ${stop_time}"
else
    bad "acctstoptime is NULL after Stop"
fi

term=$(sql_scalar "SELECT acctterminatecause FROM radacct WHERE acctsessionid='${SESSION_ID}';")
if [[ "${term}" == "User-Request" ]]; then
    ok "acctterminatecause = User-Request"
else
    bad "acctterminatecause = '${term}' (expected User-Request)"
fi

# ---------------------------------------------------------------------------
echo
echo "------------------------------------------------------------"
echo "test-accounting.sh: ${PASS} passed, ${FAIL} failed"
echo "------------------------------------------------------------"

if (( FAIL > 0 )); then
    exit 1
fi
exit 0
