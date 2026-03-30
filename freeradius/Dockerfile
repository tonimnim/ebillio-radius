FROM freeradius/freeradius-server:3.2.7

RUN apt-get update && apt-get install -y --no-install-recommends gettext-base \
    && rm -rf /var/lib/apt/lists/*

COPY clients.conf.template /etc/freeradius/templates/clients.conf.template
COPY sql.template /etc/freeradius/templates/sql.template
COPY default /etc/freeradius/sites-enabled/default
COPY docker-entrypoint.sh /docker-entrypoint.sh

RUN mkdir -p /etc/freeradius/templates \
    && chown -R freerad:freerad /etc/freeradius/templates /etc/freeradius/sites-enabled/default \
    && chmod 640 /etc/freeradius/templates/* /etc/freeradius/sites-enabled/default \
    && chmod +x /docker-entrypoint.sh

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["freeradius", "-f"]
