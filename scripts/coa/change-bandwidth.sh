#!/usr/bin/env bash
#
# change-bandwidth.sh - Send an RFC 5176 CoA-Request that reshapes a
# live MikroTik subscriber session using the Mikrotik-Rate-Limit VSA.
#
# This is the "change plan on the fly" primitive the billing platform
# uses to:
#   - upgrade a subscriber when they top up,
#   - downgrade / throttle a delinquent subscriber before full cutoff,
#   - push them to a walled-garden-rate (e.g. 256k/256k).
#
# Usage:
#   change-bandwidth.sh <nas-ip> <coa-secret> <username> <acct-session-id> <rate-limit> [port]
#
# Arguments:
#   nas-ip          IP of the MikroTik that owns the session.
#   coa-secret      Per-NAS shared secret for CoA (see disconnect-user.sh).
#   username        User-Name from the active Accounting-Request.
#   acct-session-id Acct-Session-Id from the active Accounting-Request.
#                   Wrong value -> Error-Cause 503 Session-Context-Not-Found.
#   rate-limit      Mikrotik-Rate-Limit value, e.g.
#                       "10M/10M"             (rx/tx)
#                       "10M/10M 20M/20M"     (rx/tx burst)
#                       "5M/5M 10M/10M 8M/8M 1/1 8 5M/5M"
#                   See https://wiki.mikrotik.com/wiki/Manual:RADIUS_Client
#   port            Optional. Defaults to 1700 (MikroTik).
#                   Use 3799 for non-MikroTik vendors (the Mikrotik VSA
#                   obviously only works against MikroTik gear, but the
#                   port override is useful if RouterOS has been
#                   reconfigured to listen on 3799).
#
# Example - throttle alice to 1M/1M:
#   ./change-bandwidth.sh 10.0.0.1 s3cr3t alice@isp 0x12345678 "1M/1M"
#
# Example - upgrade bob to 50M/10M burst 80M/20M:
#   ./change-bandwidth.sh 10.0.0.1 s3cr3t bob@isp 0xdeadbeef "50M/10M 80M/20M"
#
# Non-MikroTik vendors: replace Mikrotik-Rate-Limit with the
# equivalent VSA for your gear, for example:
#   Cisco:    Cisco-AVPair = "ip:sub-qos-policy-out=<policy>"
#   Juniper:  ERX-Service-Activate = "<service>"
#   Huawei:   Huawei-Input-Average-Rate / Huawei-Output-Average-Rate
# and call radclient with coa (not disconnect).
#
set -euo pipefail

if [ "$#" -lt 5 ] || [ "$#" -gt 6 ]; then
    echo "Usage: $0 <nas-ip> <coa-secret> <username> <acct-session-id> <rate-limit> [port]" >&2
    exit 2
fi

NAS_IP="$1"
SECRET="$2"
USERNAME="$3"
SESSION_ID="$4"
RATE_LIMIT="$5"
PORT="${6:-1700}"   # MikroTik default; override to 3799 for other vendors.

printf 'User-Name = "%s"\nAcct-Session-Id = "%s"\nMikrotik-Rate-Limit = "%s"\n' \
    "${USERNAME}" "${SESSION_ID}" "${RATE_LIMIT}" \
  | radclient -x "${NAS_IP}:${PORT}" coa "${SECRET}"
