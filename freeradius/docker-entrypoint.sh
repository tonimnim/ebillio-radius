#!/bin/sh
set -e

# Validate required environment variables
: "${RADIUS_SECRET:?RADIUS_SECRET is required}"
: "${DB_USERNAME:?DB_USERNAME is required}"
: "${DB_PASSWORD:?DB_PASSWORD is required}"

# Template environment variables into FreeRADIUS configs using envsubst
envsubst '${RADIUS_SECRET}' \
    < /etc/freeradius/templates/clients.conf.template \
    > /etc/freeradius/clients.conf

envsubst '${DB_USERNAME} ${DB_PASSWORD}' \
    < /etc/freeradius/templates/sql.template \
    > /etc/freeradius/mods-enabled/sql

# Set correct ownership and permissions
chown freerad:freerad /etc/freeradius/clients.conf /etc/freeradius/mods-enabled/sql
chmod 640 /etc/freeradius/clients.conf /etc/freeradius/mods-enabled/sql

exec "$@"
