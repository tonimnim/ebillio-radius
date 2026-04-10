#!/usr/bin/env bash
# ============================================================================
# run-all.sh  --  invokes each test script in sequence and reports totals.
#
# Usage:
#   ./tests/run-all.sh           # run auth, accounting, coa
#   ./tests/run-all.sh --clean   # also wipe test data when finished
#   ./tests/run-all.sh -h        # help
#
# Exits non-zero if ANY test script failed.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLEAN=0
while (( $# > 0 )); do
    case "$1" in
        --clean) CLEAN=1; shift ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown flag: $1" >&2
            exit 2
            ;;
    esac
done

# Source .env at the repo root so child scripts inherit the secrets.
if [[ -f "${REPO_ROOT}/.env" ]]; then
    # shellcheck disable=SC1091
    set -a; . "${REPO_ROOT}/.env"; set +a
fi

: "${RADIUS_SECRET:?RADIUS_SECRET is not set (populate .env)}"
: "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD is not set (populate .env)}"

TESTS=(
    "${SCRIPT_DIR}/test-auth.sh"
    "${SCRIPT_DIR}/test-accounting.sh"
    "${SCRIPT_DIR}/test-coa.sh"
)

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

PASSED=0
FAILED=0
FAILED_NAMES=()

for t in "${TESTS[@]}"; do
    name="$(basename "${t}")"
    if [[ ! -x "${t}" ]]; then
        chmod +x "${t}" || true
    fi
    if "${t}"; then
        PASSED=$((PASSED+1))
    else
        FAILED=$((FAILED+1))
        FAILED_NAMES+=("${name}")
    fi
done

echo
echo "============================================================"
echo " run-all.sh summary"
echo "   scripts passed: ${PASSED}"
echo "   scripts failed: ${FAILED}"
if (( FAILED > 0 )); then
    red "   failed: ${FAILED_NAMES[*]}"
fi
echo "============================================================"

if (( CLEAN == 1 )); then
    yellow "--clean: wiping test data"
    docker exec -i ebillio-mysql \
        mysql -uroot -p"${DB_ROOT_PASSWORD}" radius \
        < "${REPO_ROOT}/sql/clean-test-data.sql"
    green "test data removed"
fi

if (( FAILED > 0 )); then
    exit 1
fi
exit 0
