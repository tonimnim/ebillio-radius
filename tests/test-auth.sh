#!/usr/bin/env bash
# ============================================================================
# test-auth.sh  --  radclient-driven authentication tests
#
# Verifies (against a running docker compose stack):
#   1. Access-Accept for testuser-pap with correct password (PAP)
#   2. Access-Reject for testuser-pap with a wrong password
#   3. Access-Reject for testuser-blocked (Auth-Type := Reject)
#   4. The Access-Accept for testuser-pap carries Mikrotik-Rate-Limit,
#      proving that the radusergroup -> radgroupreply chain is wired up
#   5. Access-Accept for testuser-chap via CHAP
#
# Prerequisites:
#   - `make up` (stack is running)
#   - `make seed` (test rows are in the DB)
#   - RADIUS_SECRET available in env or .env at repo root
#
# Transport: all radclient calls run INSIDE the radius-server container so
# we do not depend on radclient being installed on the host. Source IP is
# 127.0.0.1 from FreeRADIUS's point of view, which matches the localhost
# client in clients.conf and the test_localhost NAS seeded in the DB.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---- load RADIUS_SECRET from env or .env -----------------------------------
if [[ -z "${RADIUS_SECRET:-}" ]]; then
    if [[ -f "${REPO_ROOT}/.env" ]]; then
        # shellcheck disable=SC1091
        set -a; . "${REPO_ROOT}/.env"; set +a
    fi
fi

: "${RADIUS_SECRET:?RADIUS_SECRET is not set (export it or populate .env)}"

RADIUS_CONTAINER="${RADIUS_CONTAINER:-radius-server}"
RADIUS_HOST="${RADIUS_HOST:-127.0.0.1}"
RADIUS_AUTH_PORT="${RADIUS_AUTH_PORT:-1812}"

PASS=0
FAIL=0

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

ok()   { green "  PASS  $*"; PASS=$((PASS+1)); }
bad()  { red   "  FAIL  $*"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------------------
# radclient wrapper  --  pipes a RADIUS attribute block into radclient inside
# the freeradius container. $1 = packet type (auth / acct). Remaining args
# passed to radclient. Attribute lines come from stdin.
# ---------------------------------------------------------------------------
rc() {
    local ptype="$1"; shift
    docker exec -i "${RADIUS_CONTAINER}" \
        radclient -x -r 1 -t 3 \
            "${RADIUS_HOST}:${RADIUS_AUTH_PORT}" "${ptype}" "${RADIUS_SECRET}" \
            "$@"
}

# ---------------------------------------------------------------------------
# Sanity check: container up?
# ---------------------------------------------------------------------------
if ! docker ps --format '{{.Names}}' | grep -qx "${RADIUS_CONTAINER}"; then
    red "FAIL: container ${RADIUS_CONTAINER} is not running. Run 'make up' first."
    exit 2
fi

echo
yellow "=== test-auth.sh ==="
echo

# ---------------------------------------------------------------------------
# Test 1: PAP happy path  --  expect Access-Accept
# ---------------------------------------------------------------------------
echo "[1] PAP accept: testuser-pap / correct password"
out=$(printf 'User-Name = "testuser-pap"\nUser-Password = "testpass123"\n' \
    | rc auth 2>&1 || true)
if grep -q 'Received Access-Accept' <<<"${out}"; then
    ok "Access-Accept received"
else
    bad "Expected Access-Accept, got:"
    printf '%s\n' "${out}" | sed 's/^/        /'
fi

# ---------------------------------------------------------------------------
# Test 2: reply attribute  --  Mikrotik-Rate-Limit must come back
# ---------------------------------------------------------------------------
echo "[2] PAP accept carries group reply attribute (Mikrotik-Rate-Limit)"
if grep -q 'Mikrotik-Rate-Limit.*10M/10M' <<<"${out}"; then
    ok "Mikrotik-Rate-Limit = 10M/10M present in Access-Accept"
else
    bad "Mikrotik-Rate-Limit missing from Access-Accept  --  group/reply chain broken"
    printf '%s\n' "${out}" | sed 's/^/        /'
fi

# ---------------------------------------------------------------------------
# Test 3: PAP wrong password  --  expect Access-Reject
# ---------------------------------------------------------------------------
echo "[3] PAP reject: testuser-pap / wrong password"
out=$(printf 'User-Name = "testuser-pap"\nUser-Password = "WRONG-password"\n' \
    | rc auth 2>&1 || true)
if grep -q 'Received Access-Reject' <<<"${out}"; then
    ok "Access-Reject received"
else
    bad "Expected Access-Reject, got:"
    printf '%s\n' "${out}" | sed 's/^/        /'
fi

# ---------------------------------------------------------------------------
# Test 4: Auth-Type := Reject  --  expect Access-Reject even with right pw
# ---------------------------------------------------------------------------
echo "[4] Blocked user reject: testuser-blocked (Auth-Type := Reject)"
out=$(printf 'User-Name = "testuser-blocked"\nUser-Password = "testpass123"\n' \
    | rc auth 2>&1 || true)
if grep -q 'Received Access-Reject' <<<"${out}"; then
    ok "Access-Reject received for blocked user"
else
    bad "Expected Access-Reject for blocked user, got:"
    printf '%s\n' "${out}" | sed 's/^/        /'
fi

# ---------------------------------------------------------------------------
# Test 5: CHAP happy path
#
# radclient encodes CHAP automatically when the input contains a literal
# `CHAP-Password = "cleartext"` string. It computes MD5(CHAP-ID || cleartext
# || CHAP-Challenge) and replaces the value before sending. The previous
# version of this test used `Auth-Type = CHAP` which radclient rejects --
# Auth-Type is a server-side internal attribute, not a radclient input.
# ---------------------------------------------------------------------------
echo "[5] CHAP accept: testuser-chap / correct password"
out=$(printf 'User-Name = "testuser-chap"\nCHAP-Password = "testpass123"\n' \
    | rc auth 2>&1 || true)
if grep -q 'Received Access-Accept' <<<"${out}"; then
    ok "Access-Accept received for CHAP user"
else
    bad "Expected Access-Accept for testuser-chap, got:"
    printf '%s\n' "${out}" | sed 's/^/        /'
fi

# ---------------------------------------------------------------------------
echo
echo "------------------------------------------------------------"
echo "test-auth.sh: ${PASS} passed, ${FAIL} failed"
echo "------------------------------------------------------------"

if (( FAIL > 0 )); then
    exit 1
fi
exit 0
