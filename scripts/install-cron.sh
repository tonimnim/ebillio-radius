#!/usr/bin/env bash
# =============================================================================
# install-cron.sh — install the eBillio stale-session cleanup cron entry
# =============================================================================
#
# WHAT
#   Installs a host crontab entry that runs scripts/cleanup-stale-sessions.sh
#   every 5 minutes. Without this, Simultaneous-Use enforcement (see
#   docs/SIMULTANEOUS_USE.md) will lock subscribers out after the first NAS
#   reboot.
#
# WHO TO RUN AS
#   The user that owns the docker socket - typically root on the Digital
#   Ocean host, or whoever runs `docker compose`. Run with sudo if you are
#   not that user. The script writes to the user's own crontab (`crontab -e`
#   equivalent), not /etc/crontab.
#
# IDEMPOTENT
#   Safe to re-run. If the entry already exists (matched by the absolute
#   path of cleanup-stale-sessions.sh), it will not be added a second time.
#
# WHERE LOGS GO
#   /var/log/radius-cleanup.log
#   You must `touch` and `chown` this file once before the first cron run,
#   or run the install with sudo so root can create it.
#
# UNINSTALL
#   crontab -l | grep -v cleanup-stale-sessions | crontab -
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP_SCRIPT="${SCRIPT_DIR}/cleanup-stale-sessions.sh"
LOG_FILE="${EBILLIO_CRON_LOG:-/var/log/radius-cleanup.log}"
SCHEDULE="${EBILLIO_CRON_SCHEDULE:-*/5 * * * *}"

# --- Sanity checks ---------------------------------------------------------

if [[ ! -x "${CLEANUP_SCRIPT}" ]]; then
    echo "ERROR: cleanup script is missing or not executable: ${CLEANUP_SCRIPT}" >&2
    echo "       run: chmod +x ${CLEANUP_SCRIPT}" >&2
    exit 1
fi

if ! command -v crontab >/dev/null 2>&1; then
    echo "ERROR: crontab is not installed on this host." >&2
    echo "       Debian/Ubuntu:  apt-get install -y cron" >&2
    echo "       Or use the systemd timer instead: scripts/cleanup-stale-sessions.timer" >&2
    exit 1
fi

# --- Ensure log file exists and is writable --------------------------------

if [[ ! -e "${LOG_FILE}" ]]; then
    if ! touch "${LOG_FILE}" 2>/dev/null; then
        echo "WARNING: could not create ${LOG_FILE}." >&2
        echo "         Re-run with sudo, or set EBILLIO_CRON_LOG to a writable path:" >&2
        echo "             EBILLIO_CRON_LOG=/var/log/ebillio/cleanup.log $0" >&2
        exit 1
    fi
fi

# --- Build the entry -------------------------------------------------------

ENTRY_LINE="${SCHEDULE} ${CLEANUP_SCRIPT} >> ${LOG_FILE} 2>&1"
MARKER="# eBillio: stale-session cleanup (managed by scripts/install-cron.sh)"

# --- Idempotent insert -----------------------------------------------------

EXISTING="$(crontab -l 2>/dev/null || true)"

if printf '%s\n' "${EXISTING}" | grep -qF "${CLEANUP_SCRIPT}"; then
    echo "Cron entry for ${CLEANUP_SCRIPT} already exists. Nothing to do."
    echo
    echo "Current entry:"
    printf '%s\n' "${EXISTING}" | grep -F "${CLEANUP_SCRIPT}" | sed 's/^/    /'
    exit 0
fi

# Append the marker + entry, preserving any existing crontab content
{
    printf '%s\n' "${EXISTING}"
    printf '\n%s\n%s\n' "${MARKER}" "${ENTRY_LINE}"
} | crontab -

echo "Installed cron entry:"
echo "    ${ENTRY_LINE}"
echo
echo "Logs will be written to: ${LOG_FILE}"
echo "View live: tail -f ${LOG_FILE}"
echo
echo "Verify with: crontab -l"
