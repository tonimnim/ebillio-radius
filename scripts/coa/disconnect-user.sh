#!/usr/bin/env bash
#
# disconnect-user.sh - Send an RFC 5176 Disconnect-Request to a NAS
#
# Usage:
#   disconnect-user.sh <nas-ip> <coa-secret> <username> <acct-session-id> [port]
#
# Arguments:
#   nas-ip          IP address of the NAS / BRAS that currently owns the
#                   session (NOT the FreeRADIUS server). This is the box
#                   that will actually boot the subscriber off the link.
#   coa-secret      Shared secret the NAS expects for CoA/Disconnect.
#                   For MikroTik this is the secret configured under
#                   /radius add service=coa ... secret=...
#                   NOTE: this is the per-NAS secret, not ${COA_SECRET}
#                   (which protects the FreeRADIUS CoA listener itself).
#   username        Value of the User-Name attribute the NAS recorded
#                   for this session in its Accounting-Request.
#   acct-session-id Value of the Acct-Session-Id the NAS assigned. If
#                   this is wrong the NAS replies Disconnect-NAK with
#                   Error-Cause = 503 (Session-Context-Not-Found).
#   port            Optional. Defaults to 1700 (MikroTik). Use 3799 for
#                   Cisco / Juniper / Huawei / Nokia / Ruckus / most
#                   other vendors.
#
# Example (MikroTik):
#   ./disconnect-user.sh 10.0.0.1 s3cr3t alice@isp 0x12345678
#
# Example (Cisco / 3799):
#   ./disconnect-user.sh 10.0.0.1 s3cr3t alice@isp 0x12345678 3799
#
# Exit status: radclient's exit code (0 on Disconnect-ACK, non-zero on
# Disconnect-NAK or timeout).
#
set -euo pipefail

if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then
    echo "Usage: $0 <nas-ip> <coa-secret> <username> <acct-session-id> [port]" >&2
    exit 2
fi

NAS_IP="$1"
SECRET="$2"
USERNAME="$3"
SESSION_ID="$4"
PORT="${5:-1700}"   # MikroTik default; override to 3799 for other vendors.

# radclient reads VPs from stdin, one "Attribute = value" per line.
# We use printf with \n so the attribute list is well-formed.
printf 'User-Name = "%s"\nAcct-Session-Id = "%s"\n' \
    "${USERNAME}" "${SESSION_ID}" \
  | radclient -x "${NAS_IP}:${PORT}" disconnect "${SECRET}"
