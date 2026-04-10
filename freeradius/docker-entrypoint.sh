#!/bin/sh
set -e

# --- Validate required environment variables -------------------------------
: "${RADIUS_SECRET:?RADIUS_SECRET is required}"
: "${DB_USERNAME:?DB_USERNAME is required}"
: "${DB_PASSWORD:?DB_PASSWORD is required}"
: "${STATUS_SECRET:?STATUS_SECRET is required (Status-Server / monitoring)}"
: "${COA_SECRET:?COA_SECRET is required (CoA/Disconnect, must differ from RADIUS_SECRET)}"

# Enforce secret separation: CoA shared secret MUST differ from the auth
# secret. Sharing them collapses the blast radius of either being leaked.
if [ "$COA_SECRET" = "$RADIUS_SECRET" ]; then
    echo "FATAL: COA_SECRET must not equal RADIUS_SECRET" >&2
    exit 1
fi

# --- Render templates via envsubst -----------------------------------------
envsubst '${RADIUS_SECRET}' \
    < /etc/freeradius/templates/clients.conf.template \
    > /etc/freeradius/clients.conf

envsubst '${DB_USERNAME} ${DB_PASSWORD}' \
    < /etc/freeradius/templates/sql.template \
    > /etc/freeradius/mods-enabled/sql

envsubst '${STATUS_SECRET}' \
    < /etc/freeradius/templates/status-clients.conf.template \
    > /etc/freeradius/status-clients.conf

envsubst '${COA_SECRET}' \
    < /etc/freeradius/templates/coa-clients.conf.template \
    > /etc/freeradius/coa-clients.conf

# --- Set ownership and permissions on rendered files ----------------------
chown freerad:freerad \
    /etc/freeradius/clients.conf \
    /etc/freeradius/mods-enabled/sql \
    /etc/freeradius/status-clients.conf \
    /etc/freeradius/coa-clients.conf
chmod 640 \
    /etc/freeradius/clients.conf \
    /etc/freeradius/mods-enabled/sql \
    /etc/freeradius/status-clients.conf \
    /etc/freeradius/coa-clients.conf

exec "$@"
