#!/usr/bin/env bash
# =============================================================================
# setup-shared-mysql.sh -- one-shot eBillio RADIUS setup against shared MySQL
# =============================================================================
#
# Creates the `radius` database, applies the hardened schema, creates a
# dedicated `radius` MySQL user with least-privilege grants, and runs the
# Simultaneous-Use backfill — all inside the backend's `ebillio-mysql`
# container.
#
# This wraps the SQL in sql/setup-radius-on-shared-mysql.sql with the
# messy bits handled in bash (file staging, password injection, quoting).
# See that file's header for background and rollback steps.
#
# ENVIRONMENT
#   DB_ROOT_PASSWORD   Required. Root password of the SHARED ebillio-mysql
#                      container (from the backend's .env, not ours).
#   DB_PASSWORD        Required. Password to set on the new `radius` MySQL
#                      user (from our .env — repo-owned, freshly rotated).
#   MYSQL_CONTAINER    Optional. Default: ebillio-mysql.
#
# USAGE
#   From the repo root:
#     export $(grep -v '^#' .env | xargs)    # load our .env
#     bash scripts/setup-shared-mysql.sh
#
#   Or:    make setup-shared-mysql
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MYSQL_CONTAINER="${MYSQL_CONTAINER:-ebillio-mysql}"

# --- Preflight -------------------------------------------------------------

if [[ -z "${DB_ROOT_PASSWORD:-}" ]]; then
    cat >&2 <<EOF
ERROR: DB_ROOT_PASSWORD is not set.

This must be the SHARED MySQL's root password (the backend's root password),
not a value we rotated. Look in the backend repo's .env for MYSQL_ROOT_PASSWORD
or similar, then either:

    export DB_ROOT_PASSWORD='...'         # this shell only, preferred
    # or add it to this repo's .env (still gitignored)

Then re-run: bash scripts/setup-shared-mysql.sh
EOF
    exit 1
fi

if [[ -z "${DB_PASSWORD:-}" ]]; then
    echo "ERROR: DB_PASSWORD is not set. Populate .env first." >&2
    exit 1
fi

if ! docker inspect -f '{{.State.Running}}' "${MYSQL_CONTAINER}" 2>/dev/null | grep -q true; then
    echo "ERROR: container '${MYSQL_CONTAINER}' is not running." >&2
    echo "       Start the backend stack first, then re-run." >&2
    exit 1
fi

# --- Copy SQL files into the container ------------------------------------

echo "Staging SQL files into ${MYSQL_CONTAINER}..."
docker cp "${REPO_ROOT}/sql/schema.sql" \
    "${MYSQL_CONTAINER}:/tmp/ebillio-radius-schema.sql"
docker cp "${REPO_ROOT}/sql/migrations/002_backfill_simultaneous_use.sql" \
    "${MYSQL_CONTAINER}:/tmp/ebillio-radius-sim-use.sql"
docker cp "${REPO_ROOT}/sql/setup-radius-on-shared-mysql.sql" \
    "${MYSQL_CONTAINER}:/tmp/ebillio-radius-setup.sql"

# --- Run the setup SQL -----------------------------------------------------
#
# We inject DB_PASSWORD via a `SET @radius_pw := ...` prelude that we
# concatenate to the setup script on the fly. The password never touches
# the shell command line, `ps`, or the container filesystem — it lives
# in the pipe stream for the duration of the mysql process.
#
# Quoting: we escape any single quotes in DB_PASSWORD by doubling them,
# which is the SQL-standard way inside a single-quoted string literal.

escaped_pw="${DB_PASSWORD//\'/\'\'}"

echo "Applying schema, creating radius user, applying grants..."
{
    printf "SET @radius_pw := '%s';\n" "${escaped_pw}"
    # The setup script SOURCEs /tmp/ebillio-radius-schema.sql and
    # /tmp/ebillio-radius-sim-use.sql which we just copied above.
    docker exec -i "${MYSQL_CONTAINER}" cat /tmp/ebillio-radius-setup.sql
} | docker exec -i \
        -e MYSQL_PWD="${DB_ROOT_PASSWORD}" \
        "${MYSQL_CONTAINER}" \
        mysql -uroot

# --- Clean up staged files -------------------------------------------------
docker exec "${MYSQL_CONTAINER}" rm -f \
    /tmp/ebillio-radius-schema.sql \
    /tmp/ebillio-radius-sim-use.sql \
    /tmp/ebillio-radius-setup.sql

echo
echo "Shared MySQL is set up. Next steps:"
echo "  1. make up                # start FreeRADIUS against the shared MySQL"
echo "  2. docker compose logs -f freeradius   # watch for auth/acct"
