#!/usr/bin/env bash
# ============================================================================
# test-coa.sh  --  CoA / Disconnect-Request smoke test
#
# DEPENDENCY NOTE
# ---------------
# This test depends on work from ANOTHER agent that is expected to add a
# Change-of-Authorization (CoA) listener to FreeRADIUS. Concretely it
# expects:
#   * A sites-enabled config (e.g. sites-enabled/coa) that enables a
#     `listen { type = coa ... port = 3799 ... }` stanza.
#   * The compose file exposing UDP 3799 (or the CoA port chosen) on the
#     host; or at minimum the port being reachable from inside the
#     radius-server container (which is what this script uses).
#   * A COA_SECRET environment variable. If unset we fall back to
#     RADIUS_SECRET, which matches FreeRADIUS's common default where the CoA
#     client shares the client secret.
#
# If the listener is not enabled, the test prints SKIPPED and exits 0 so
# the run-all runner does not fail on a feature that has not landed yet.
#
# What this test does
# -------------------
#   1. Seeds a fake "live" session directly into radacct (no active NAS).
#   2. Sends a Disconnect-Request via radclient on the CoA port.
#   3. Expects a Disconnect-ACK reply.
#   4. (Optional) Verifies that the session row is marked closed. Since no
#      real NAS is there to close it, FreeRADIUS itself will normally only
#      relay the Disconnect; the row closure check is best-effort.
#
# This is a SMOKE TEST, not a full integration test. It proves the CoA
# listener is reachable and accepts packets signed with the shared secret.
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

COA_SECRET="${COA_SECRET:-${RADIUS_SECRET}}"
COA_PORT="${COA_PORT:-3799}"
RADIUS_CONTAINER="${RADIUS_CONTAINER:-radius-server}"
MYSQL_CONTAINER="${MYSQL_CONTAINER:-ebillio-mysql}"
RADIUS_HOST="${RADIUS_HOST:-127.0.0.1}"

SESSION_ID="test-coa-$(date +%s)-$$"
ACCT_USER="testuser-pap"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

echo
yellow "=== test-coa.sh  (session ${SESSION_ID}) ==="
echo

# ---------------------------------------------------------------------------
# Preflight: is the stack up?
# ---------------------------------------------------------------------------
if ! docker ps --format '{{.Names}}' | grep -qx "${RADIUS_CONTAINER}"; then
    red "FAIL: container ${RADIUS_CONTAINER} is not running. Run 'make up' first."
    exit 2
fi

# ---------------------------------------------------------------------------
# Detect whether a CoA listener is enabled. The probe: is anything listening
# on COA_PORT/UDP inside the container? We use `ss` if available, else
# fall back to trying the radclient request and inspecting the outcome.
# ---------------------------------------------------------------------------
coa_enabled=0
if docker exec "${RADIUS_CONTAINER}" sh -c "command -v ss >/dev/null 2>&1"; then
    if docker exec "${RADIUS_CONTAINER}" \
        sh -c "ss -lnu 2>/dev/null | awk '{print \$5}' | grep -q ':${COA_PORT}\$'"; then
        coa_enabled=1
    fi
fi

# Also check the sites directories for a `type = coa` listen stanza as a
# backup signal (does not require ss). Use grep -R (capital R) so it
# follows symlinks -- sites-enabled/coa is typically a symlink to
# sites-available/coa, which `grep -r` (lowercase) will not traverse.
if (( coa_enabled == 0 )); then
    if docker exec "${RADIUS_CONTAINER}" \
        sh -c "grep -RqsE 'type[[:space:]]*=[[:space:]]*coa' /etc/freeradius/sites-enabled/ /etc/freeradius/sites-available/ 2>/dev/null"; then
        coa_enabled=1
    fi
fi

if (( coa_enabled == 0 )); then
    yellow "SKIPPED: no CoA listener detected on port ${COA_PORT}."
    yellow "         (Depends on another agent's CoA work  --  sites-enabled/coa,"
    yellow "          COA_SECRET env var, UDP ${COA_PORT} exposed.)"
    exit 0
fi

# ---------------------------------------------------------------------------
# Seed a fake live session into radacct so there is something to disconnect.
# ---------------------------------------------------------------------------
cleanup() {
    docker exec -i "${MYSQL_CONTAINER}" \
        mysql -uroot -p"${DB_ROOT_PASSWORD}" radius \
        -e "DELETE FROM radacct WHERE acctsessionid='${SESSION_ID}';" \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker exec -i "${MYSQL_CONTAINER}" \
    mysql -uroot -p"${DB_ROOT_PASSWORD}" radius <<EOF >/dev/null
INSERT INTO radacct
    (acctsessionid, acctuniqueid, username, nasipaddress,
     acctstarttime, framedipaddress)
VALUES
    ('${SESSION_ID}', MD5('${SESSION_ID}'), '${ACCT_USER}',
     '127.0.0.1', NOW(), '10.99.0.99');
EOF

PASS=0
FAIL=0
ok()  { green "  PASS  $*"; PASS=$((PASS+1)); }
bad() { red   "  FAIL  $*"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------------------
# Send a Disconnect-Request
# ---------------------------------------------------------------------------
echo "[1] Disconnect-Request to ${RADIUS_HOST}:${COA_PORT}"
# Message-Authenticator=0x00 is a placeholder radclient auto-fills with
# the proper HMAC before sending. Our hardened CoA listener enforces
# require_message_authenticator=yes (Blast-RADIUS mitigation / defense
# in depth), so packets without this attribute are silently dropped.
dis_pkt=$(cat <<EOF
User-Name = "${ACCT_USER}"
Acct-Session-Id = "${SESSION_ID}"
NAS-IP-Address = 127.0.0.1
Framed-IP-Address = 10.99.0.99
Message-Authenticator = 0x00
EOF
)
out=$(printf '%s\n' "${dis_pkt}" | \
    docker exec -i "${RADIUS_CONTAINER}" \
    radclient -x -r 1 -t 3 \
        "${RADIUS_HOST}:${COA_PORT}" disconnect "${COA_SECRET}" 2>&1 || true)

if grep -qE 'Disconnect-ACK|Received Disconnect-ACK' <<<"${out}"; then
    ok "Disconnect-ACK received"
elif grep -qE 'Disconnect-NAK' <<<"${out}"; then
    bad "Disconnect-NAK received  --  listener up but rejected the request:"
    printf '%s\n' "${out}" | sed 's/^/        /'
else
    bad "No Disconnect-ACK in reply:"
    printf '%s\n' "${out}" | sed 's/^/        /'
fi

# Best-effort: see if radacct row got closed.
stop_time=$(docker exec -i "${MYSQL_CONTAINER}" \
    mysql -N -B -uroot -p"${DB_ROOT_PASSWORD}" radius \
    -e "SELECT IFNULL(acctstoptime,'') FROM radacct WHERE acctsessionid='${SESSION_ID}';" \
    2>/dev/null || true)
if [[ -n "${stop_time}" ]]; then
    ok "radacct row closed (acctstoptime=${stop_time})"
else
    yellow "  INFO  radacct row not closed  --  expected when no real NAS is handling Disconnect"
fi

echo
echo "------------------------------------------------------------"
echo "test-coa.sh: ${PASS} passed, ${FAIL} failed"
echo "------------------------------------------------------------"

if (( FAIL > 0 )); then
    exit 1
fi
exit 0
