# eBillio RADIUS Monitoring

This directory wires the eBillio FreeRADIUS + MySQL stack into a Prometheus /
Grafana monitoring pipeline. The exporters themselves live in the top-level
`docker-compose.yml`; this directory holds the scrape config, the Grafana
dashboard pointer, and the operator runbook.

## Architecture

```
   FreeRADIUS (Status-Server on 127.0.0.1:18121 inside the container)
        |
        | RADIUS Status-Server probes (UDP, client secret = STATUS_SECRET)
        v
   freeradius_exporter (bvantagelimited/freeradius_exporter:0.1.9)
        |  /metrics on :9812
        v
   Prometheus  <----  mysqld_exporter (prom/mysqld-exporter, :9104)
        |
        v
   Grafana (dashboard 19891 "FreeRADIUS")
```

Everything runs on the compose network, so Prometheus scrapes the exporters
by docker-compose service name (`freeradius_exporter:9812`,
`mysqld_exporter:9104`). The exporter ports are also published on
`127.0.0.1` on the host for local debugging only.

## Dependencies / prerequisites

1. **Status-Server must be enabled in FreeRADIUS.** Another agent/task is
   responsible for enabling `sites-available/status`, symlinking it into
   `sites-enabled/`, adding a `client localhost_status { ipaddr = 127.0.0.1
   secret = ${STATUS_SECRET} }` block to `clients.conf`, and making sure the
   status virtual server listens on `127.0.0.1:18121`. Until that lands:
   - the FreeRADIUS container healthcheck (`/healthcheck.sh`, which runs
     `radclient status`) will fail and the container will report `unhealthy`,
     and
   - `freeradius_exporter` will produce `freeradius_stats_error=1` and no
     useful metrics.
2. **`STATUS_SECRET` must be set** in `.env` (and is passed into both the
   `freeradius` and `freeradius_exporter` services). Pick a long random
   value, e.g. `openssl rand -hex 32`.
3. **`MYSQLD_EXPORTER_PASSWORD` must be set** in `.env` and must match the
   password of the `exporter`@`%` MySQL user (see SQL snippet below).

Add to `.env` (do not commit real secrets):

```env
STATUS_SECRET=replace-with-random-hex
MYSQLD_EXPORTER_PASSWORD=replace-with-random-hex
```

## Creating the mysqld_exporter user

`mysqld_exporter` needs a read-only MySQL user with `PROCESS`, `REPLICATION
CLIENT`, and `SELECT` on `performance_schema`. Create it once, manually, as
an operator:

```sql
-- Run as root (or another account with GRANT OPTION) on the mysql service:
--   docker compose exec mysql mysql -uroot -p
CREATE USER IF NOT EXISTS 'exporter'@'%'
  IDENTIFIED BY 'replace-with-random-hex'
  WITH MAX_USER_CONNECTIONS 3;

GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'%';
-- SELECT on *.* is intentionally broad; mysqld_exporter collects schema
-- stats. If you want to lock it down further, restrict SELECT to
-- performance_schema, information_schema, and sys.

FLUSH PRIVILEGES;
```

Put the same password in `.env` as `MYSQLD_EXPORTER_PASSWORD`. This user is
intentionally **not** created by `sql/schema.sql` -- it is an operational
concern, not a schema concern.

## Running

```sh
# Boot the stack (includes both exporters now).
docker compose up -d

# Check that everything is healthy.
docker compose ps
# freeradius should go from "starting" to "healthy" within ~30s once
# Status-Server is enabled.

# Verify the FreeRADIUS exporter is scraping Status-Server:
curl -s http://127.0.0.1:9812/metrics | grep -E '^freeradius_(total_access|state|stats_error)'

# Verify the MySQL exporter:
curl -s http://127.0.0.1:9104/metrics | grep -E '^mysql_up'
# Expected: mysql_up 1
```

If `mysql_up 0`, re-check the `exporter` user password vs. `.env`.

If `freeradius_stats_error 1`, re-check the Status-Server site, the
`localhost_status` client block, and `STATUS_SECRET`.

## Prometheus

`monitoring/prometheus.yml` is a minimal scrape config. Two deployment
options:

### Option A: run Prometheus in the same docker-compose (recommended)

Append to `docker-compose.yml`:

```yaml
  prometheus:
    image: prom/prometheus:v2.53.0
    container_name: radius-prometheus
    restart: unless-stopped
    volumes:
      - ./monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    ports:
      - "127.0.0.1:9090:9090"
    depends_on:
      - freeradius_exporter
      - mysqld_exporter
```

and add `prometheus_data:` under `volumes:`. No changes needed to
`prometheus.yml` -- the service-name-based targets resolve in the compose
network.

### Option B: run Prometheus outside compose

Edit `monitoring/prometheus.yml` and change the targets from
`freeradius_exporter:9812` / `mysqld_exporter:9104` to `127.0.0.1:9812` /
`127.0.0.1:9104` (or `host.docker.internal:PORT` if Prometheus itself is
dockerised on the same host).

## Grafana dashboard

See `monitoring/grafana-dashboard-19891.json` for import instructions. The
short version: in Grafana UI, Dashboards -> New -> Import -> `19891` ->
select your `prometheus` datasource. Alternative dashboard ID: `19111`.

## Recommended alerts

These are starting points; tune thresholds to your traffic profile.

```yaml
groups:
  - name: freeradius
    rules:
      - alert: FreeRADIUSDown
        expr: up{job="freeradius"} == 0
        for: 2m
        labels: { severity: critical }
        annotations:
          summary: "FreeRADIUS exporter is unreachable"

      - alert: FreeRADIUSStatsError
        expr: freeradius_stats_error == 1
        for: 5m
        labels: { severity: warning }
        annotations:
          summary: "freeradius_exporter cannot talk to Status-Server"

      - alert: FreeRADIUSHighRejectRate
        expr: |
          sum(rate(freeradius_total_access_rejects[5m]))
          /
          clamp_min(sum(rate(freeradius_total_access_requests[5m])), 1)
          > 0.5
        for: 10m
        labels: { severity: warning }
        annotations:
          summary: "More than 50% of access requests are being rejected"

      - alert: FreeRADIUSAuthQueueBacklog
        expr: freeradius_queue_len_auth > 100
        for: 5m
        labels: { severity: warning }
        annotations:
          summary: "Auth queue length is backing up"

      - alert: FreeRADIUSHomeServerDead
        # state: Alive=0, Zombie=1, Dead=2, Idle=3
        expr: freeradius_state == 2
        for: 1m
        labels: { severity: critical }
        annotations:
          summary: "A FreeRADIUS home server / NAS is marked dead"

  - name: mysql
    rules:
      - alert: MySQLDown
        expr: mysql_up == 0
        for: 2m
        labels: { severity: critical }
        annotations:
          summary: "mysqld_exporter cannot reach MySQL"

      - alert: MySQLTooManyConnections
        expr: |
          mysql_global_status_threads_connected
          / mysql_global_variables_max_connections > 0.8
        for: 5m
        labels: { severity: warning }
        annotations:
          summary: "MySQL connection pool is >80% full"
```

## References

- FreeRADIUS Status-Server: https://wiki.freeradius.org/config/Status
- bvantagelimited/freeradius_exporter: https://github.com/bvantagelimited/freeradius_exporter
- prom/mysqld_exporter: https://github.com/prometheus/mysqld_exporter
- Grafana dashboard 19891 (FreeRADIUS): https://grafana.com/grafana/dashboards/19891-freeradius/
- Grafana dashboard 19111 (alternative): https://grafana.com/grafana/dashboards/19111
