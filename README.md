# eBillio RADIUS Server

Standalone FreeRADIUS + MySQL stack for eBillio ISP billing platform.

## Setup

1. Copy `.env.example` to `.env` and fill in your secrets:
   ```bash
   cp .env.example .env
   ```

2. Edit `.env` with your credentials:
   - `RADIUS_SECRET` — shared secret between NAS devices and RADIUS
   - `DB_ROOT_PASSWORD` — MySQL root password
   - `DB_USERNAME` — MySQL user for FreeRADIUS
   - `DB_PASSWORD` — MySQL password for FreeRADIUS

3. Add your NAS devices to `freeradius/clients.conf` (specific IPs, not 0.0.0.0/0).

## Deploy
```bash
docker compose up -d --build
```

## Test
```bash
radtest testuser testpass <server-ip> 0 <radius-secret>
```

## Adding NAS Clients

Edit `freeradius/clients.conf` and add entries for each NAS/router:
```
client site_name {
    ipaddr = <nas-ip-or-subnet>
    secret = __RADIUS_SECRET__
    require_message_authenticator = yes
    nastype = other
}
```
Then rebuild: `docker compose up -d --build`

Alternatively, add NAS entries to the `nas` table in MySQL for dynamic client loading.

## Firewall (ufw)

MySQL port 3306 is exposed for the Railway web app to manage subscribers. Lock down the VPS with ufw:

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp        # SSH
ufw allow 1812/udp      # RADIUS auth
ufw allow 1813/udp      # RADIUS accounting
ufw allow 3306/tcp      # MySQL (for Railway web app)
ufw enable
```
