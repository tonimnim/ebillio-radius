# Production Deployment Checklist

This is the runbook for taking the `feature/hardening-pass-1` branch from the local dev machine to the Digital Ocean production host. Work top to bottom — do not skip items.

---

## 0. Prerequisites on the DO host

- Docker + Docker Compose v2 installed
- The **backend stack** is already running (or you can bring it up before this one)
- Ports `1812/udp`, `1813/udp`, `1700/udp`, `3799/udp`, `18121/udp`, `9812/tcp` are free
- SSH access as a non-root user with docker group membership

---

## 1. Code deployment

```bash
# On the DO host
cd /opt
git clone <your-repo-url> ebillio-radius
cd ebillio-radius
git checkout feature/hardening-pass-1   # or main after you merge
```

---

## 2. Create and populate `.env`

**Never** copy the local dev `.env` to production — its secrets are dev-only. Generate fresh ones directly on the host:

```bash
cp .env.example .env
chmod 600 .env

# Generate 4 fresh 40-char secrets
for var in RADIUS_SECRET DB_PASSWORD STATUS_SECRET COA_SECRET; do
    val=$(openssl rand -base64 32 | tr -d '/+=' | head -c 40)
    sed -i "s|^${var}=.*|${var}=${val}|" .env
done

# Verify
awk -F= '/^[A-Z]/ {print $1"=<"length($2)" chars>"}' .env
```

Expected output:
```
RADIUS_SECRET=<40 chars>
DB_ROOT_PASSWORD=<0 chars>     # leave empty unless running seed/test/setup
DB_USERNAME=<6 chars>
DB_PASSWORD=<40 chars>
STATUS_SECRET=<40 chars>
COA_SECRET=<40 chars>
MYSQLD_EXPORTER_PASSWORD=<0 chars>   # not used yet
```

---

## 3. Bootstrap the shared MySQL

The backend's `ebillio-mysql` must be running before you do this.

```bash
# Temporarily export the BACKEND's MySQL root password for this one command
export DB_ROOT_PASSWORD='<backend MySQL root password — NOT the empty .env value>'
make setup-shared-mysql
unset DB_ROOT_PASSWORD
```

Expected output includes `setup complete`, `radius tables = 8`, `radius user grants = 0` (the verification query counts schema-level grants, which are zero; the table-level grants are present — verify with `make shell-mysql` → `SHOW GRANTS FOR 'radius'@'%';` if you want to check).

---

## 4. Apply the hardening ALTER migration

Only run this if the `radacct` table is **empty** (or you have a maintenance window). It rewrites the table.

```bash
export DB_ROOT_PASSWORD='<backend MySQL root password>'
make hardening-alter
unset DB_ROOT_PASSWORD
```

Expected output: `partition count = 13`, `acctinputoctets is unsigned = YES`, `new indexes present = 5`. The migration is idempotent — re-running it on an already-partitioned table is a safe no-op.

---

## 5. Bring up the RADIUS stack

```bash
make up
```

Verify both containers come up healthy:

```bash
docker compose ps
# expect:
#   radius-server                 Up (healthy)
#   radius-freeradius-exporter    Up

ss -lun | grep -E ':(1812|1813|1700|3799|18121)'
# expect 5 lines, all 0.0.0.0:<port>
```

---

## 6. End-to-end smoke test

```bash
# Seed test users
export DB_ROOT_PASSWORD='<backend MySQL root password>'
make seed

# Run the full suite — expect 15/15 tests pass
make test

unset DB_ROOT_PASSWORD

# Verify the exporter is scraping real metrics
curl -s http://127.0.0.1:9812/metrics | grep ^freeradius_total_access_requests
```

If any test fails, stop and investigate — do **not** push production traffic to a broken stack.

---

## 7. Install the stale-session cleanup cron

**This is mandatory** — without it, Simultaneous-Use enforcement will lock users out the first time a NAS reboots.

```bash
# Option A: cron (simpler)
sudo touch /var/log/radius-cleanup.log
sudo chown $USER:$USER /var/log/radius-cleanup.log
make install-cron
crontab -l | grep cleanup-stale-sessions   # verify the entry exists

# Option B: systemd timer (alternative)
sudo cp scripts/cleanup-stale-sessions.service /etc/systemd/system/
sudo cp scripts/cleanup-stale-sessions.timer   /etc/systemd/system/
# edit the .service file's ExecStart path to match /opt/ebillio-radius
sudo systemctl daemon-reload
sudo systemctl enable --now cleanup-stale-sessions.timer
systemctl list-timers cleanup-stale-sessions.timer
```

---

## 8. Host firewall

**Deny everything inbound except what the service actually needs.** The FreeRADIUS container binds all RADIUS ports to `0.0.0.0` (host networking), so the host firewall is your ONLY access control at the network layer.

```bash
# Replace <nas-public-ip> with each real NAS's public IP
# Replace <admin-ip> with your management/bastion IP

sudo ufw default deny incoming
sudo ufw default allow outgoing

sudo ufw allow from <admin-ip> to any port 22 proto tcp comment 'SSH'

# RADIUS auth + accounting from each NAS
for nas in <nas-public-ip-1> <nas-public-ip-2>; do
    sudo ufw allow from $nas to any port 1812 proto udp comment "RADIUS auth from $nas"
    sudo ufw allow from $nas to any port 1813 proto udp comment "RADIUS acct from $nas"
done

# CoA OUTBOUND only — backend sends TO the NAS, not the other way around
# (so no inbound ufw rule needed for 1700/3799 unless a NAS is probing back)

# DO NOT open 3306 (MySQL) or 9812 (exporter) or 18121 (status) externally
# Prometheus scraping should go over SSH tunnel or WireGuard, never public

sudo ufw enable
sudo ufw status verbose
```

---

## 9. NAS (MikroTik) configuration

On **every** MikroTik router that will authenticate against this RADIUS:

```
# Add the RADIUS server
/radius add service=ppp,hotspot,login,wireless \
    address=<ebillio-radius-host-public-ip> \
    secret=<RADIUS_SECRET from .env> \
    authentication-port=1812 \
    accounting-port=1813 \
    timeout=3s \
    comment="eBillio RADIUS"

# Enable incoming CoA (port 1700 is MikroTik default)
/radius incoming set accept=yes port=1700

# Firewall: allow inbound CoA from the backend's public IP
/ip firewall filter add chain=input protocol=udp dst-port=1700 \
    src-address=<backend-public-ip> action=accept \
    comment="eBillio CoA"

# Turn on RADIUS auth + accounting for PPPoE
/ppp aaa set use-radius=yes accounting=yes interim-update=5m

# Critical: make sure RouterOS is at least 7.15 so it sends
# Message-Authenticator on Access-Request (required by our Blast-RADIUS
# hardening). Check with: /system resource print
```

---

## 10. Compliance & legal

- **ODPC Kenya registration** if the ISP is above the DPA thresholds (KES 5M turnover + 10 employees)
- **Data Processing Agreement** between eBillio (processor) and each ISP customer (controller) — template should cover Kenya DPA Sec 42, POPIA, NDPA processor obligations
- **Retention policy:** 12 months hot `radacct` + 24 months archived (aggregated/pseudonymised). Kenya KICA minimum is 3 years.
- **Incident response runbook** with 72h notification to ODPC on breach

See `docs/SECRETS.md` for the secrets-rotation playbook, and the `reference_radius_research.md` memory for the compliance research.

---

## 11. Monitoring setup (optional, recommended)

The Prometheus exporter is already running on `127.0.0.1:9812`. To scrape it from outside the host, use one of:

1. **SSH reverse tunnel** from your Grafana host: `ssh -R 9812:127.0.0.1:9812 prometheus-host`
2. **WireGuard** between the DO host and your monitoring VPC
3. **Port-forward through a Nginx reverse proxy** with basic auth + TLS on `https://monitoring.ebillio.internal/metrics/freeradius`

Import Grafana dashboard **19891** (FreeRADIUS by bvantagelimited) with the Prometheus datasource pointing at the scrape target.

---

## 12. Auto-start on reboot

Both containers already have `restart: unless-stopped`. Verify docker is enabled to start on boot:

```bash
sudo systemctl enable docker
sudo systemctl is-enabled docker       # should print: enabled
```

Reboot the host once to prove the stack comes back clean:

```bash
sudo reboot

# After reconnecting:
docker compose ps                       # both containers Up
make test                               # full smoke test
```

---

## 13. Final audit — is this actually production grade?

Run through this checklist. Every answer should be **yes**:

- [ ] `.env` has all 5 secrets (RADIUS, DB_PASSWORD, STATUS, COA, MYSQLD_EXPORTER) with 32+ chars each
- [ ] `.env` is `chmod 600` and gitignored (verify with `git check-ignore .env`)
- [ ] `git log -p -- .env` shows the file was **removed** in a past commit (verify no plaintext secrets anywhere in current HEAD)
- [ ] The original leaked secrets (`Eb1ll10_R4d1us_2026!`, etc.) do NOT match any production deployment
- [ ] `clients.conf.template` has been edited to list your REAL production NAS IPs — not `203.0.113.x` placeholders
- [ ] Every NAS has its own unique secret (not `${RADIUS_SECRET}` shared across all of them)
- [ ] MikroTik routers at RouterOS 7.15+ (for Message-Authenticator support)
- [ ] `make test` passes 15/15
- [ ] Status-Server probe returns real counters: `curl -s http://127.0.0.1:9812/metrics | head`
- [ ] CoA smoke test passed: you disconnected a live session from the backend
- [ ] Stale-session cron installed: `crontab -l | grep cleanup-stale-sessions` returns a line
- [ ] Host firewall is deny-by-default with a whitelist for known NAS IPs
- [ ] MySQL 3306 is NOT reachable from the public internet (`nmap -p3306 <host-public-ip>` from an external box shows filtered/closed)
- [ ] Prometheus scraping is going over SSH tunnel or WireGuard, not raw public
- [ ] Backup script for the `radius` DB exists and has run at least once
- [ ] `docs/SIMULTANEOUS_USE.md` — the backend's provisioning code change has been merged and deployed
- [ ] Every existing subscriber has a `Simultaneous-Use` row in `radcheck` (run `make backfill-simultaneous-use` once)
- [ ] An ODPC Kenya DPIA has been filed (or a note in your legal tracker explaining why not)

When every box is checked, the stack is production grade **for a single-host, single-region deployment**. For multi-region (US/China subscribers), see Phase 2 (RadSec / radsecproxy edge POPs) — separate effort, not covered here.
