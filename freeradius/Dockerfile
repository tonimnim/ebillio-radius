FROM freeradius/freeradius-server:3.2.7

RUN apt-get update && apt-get install -y --no-install-recommends gettext-base \
    && rm -rf /var/lib/apt/lists/*

# --- Templates (envsubst'd at container start by docker-entrypoint.sh) ---
COPY clients.conf.template       /etc/freeradius/templates/clients.conf.template
COPY sql.template                /etc/freeradius/templates/sql.template
COPY status-clients.conf         /etc/freeradius/templates/status-clients.conf.template
COPY coa-clients.conf            /etc/freeradius/templates/coa-clients.conf.template

# --- Virtual servers / sites ---
COPY default                     /etc/freeradius/sites-enabled/default
COPY status                      /etc/freeradius/sites-available/status
COPY coa                         /etc/freeradius/sites-available/coa
COPY originate-coa               /etc/freeradius/sites-available/originate-coa

# --- Security hardening (see security.conf for CVE-2024-3596 / Blast-RADIUS rationale) ---
COPY security.conf               /etc/freeradius/security.conf

# --- Scripts ---
COPY docker-entrypoint.sh        /docker-entrypoint.sh
COPY healthcheck.sh              /healthcheck.sh

# Patch radiusd.conf: replace the upstream security{} block with our hardened
# one. The security{} directives (require_message_authenticator, limit_proxy_state)
# are only valid at radiusd.conf global scope in FreeRADIUS 3.2.x — they cannot
# live in server{} or listen{} blocks. The awk script splices security.conf
# in place of the original block. Brittle to upstream format changes; image
# is pinned to 3.2.7 to mitigate.
RUN awk 'BEGIN{skip=0} /^security \{/{skip=1; while((getline line < "/etc/freeradius/security.conf") > 0) print line; next} skip==1 && /^\}/{skip=0; next} skip==0{print}' /etc/freeradius/radiusd.conf > /etc/freeradius/radiusd.conf.new \
    && mv /etc/freeradius/radiusd.conf.new /etc/freeradius/radiusd.conf \
    && chown freerad:freerad /etc/freeradius/radiusd.conf /etc/freeradius/security.conf \
    && chmod 640 /etc/freeradius/radiusd.conf /etc/freeradius/security.conf

# Symlink the new sites into sites-enabled, fix ownership/permissions on
# everything we copied, and make scripts executable.
RUN mkdir -p /etc/freeradius/templates \
    && ln -sf /etc/freeradius/sites-available/status        /etc/freeradius/sites-enabled/status \
    && ln -sf /etc/freeradius/sites-available/coa           /etc/freeradius/sites-enabled/coa \
    && ln -sf /etc/freeradius/sites-available/originate-coa /etc/freeradius/sites-enabled/originate-coa \
    && chown -R freerad:freerad \
        /etc/freeradius/templates \
        /etc/freeradius/sites-enabled/default \
        /etc/freeradius/sites-available/status \
        /etc/freeradius/sites-available/coa \
        /etc/freeradius/sites-available/originate-coa \
    && chmod 640 \
        /etc/freeradius/templates/* \
        /etc/freeradius/sites-enabled/default \
        /etc/freeradius/sites-available/status \
        /etc/freeradius/sites-available/coa \
        /etc/freeradius/sites-available/originate-coa \
    && chmod +x /docker-entrypoint.sh /healthcheck.sh

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["freeradius", "-f"]
