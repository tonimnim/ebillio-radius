#!/bin/sh
# FreeRADIUS container healthcheck.
#
# Sends a Status-Server probe to the local FreeRADIUS status listener and
# exits non-zero if the server does not reply. This depends on:
#   1. sites-available/status (and a sites-enabled symlink) being active,
#      listening on 127.0.0.1:18121.
#   2. A `client localhost_status` entry in clients.conf with secret
#      ${STATUS_SECRET}, allowing 127.0.0.1 to query it.
#   3. STATUS_SECRET being present in the container environment.
#
# NOTE: Status-Server is enabled by a sibling task/agent. Until that lands,
# this healthcheck will fail and the container will be marked unhealthy.

set -eu

: "${STATUS_SECRET:?STATUS_SECRET is not set in the container environment}"

echo "Message-Authenticator=0x00,FreeRADIUS-Statistics-Type=0x1f" | \
    radclient -x -t 2 -r 1 127.0.0.1:18121 status "${STATUS_SECRET}" > /dev/null
