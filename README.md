# odoo-512mb

Deterministic Odoo 19 deployment for a **512 MB RAM / Debian 13** VM (Vultr
$2.50 plan), aimed at ~4 users, primarily Projects.

One command deploys the whole stack. Every config lives in this repo and is
**symlinked** into the OS — the repo, not the live machine, is the source of
truth. Re-run the deploy after any edit; it is idempotent.

## Architecture

```text
Internet
   │ :443 (nginx TLS, self-signed by default)
   ▼
Nginx ── gzip ── disk asset cache (/web/assets/ 30d, /web/static/ 7d, /web/image/ 1d)
   │
   ▼
Odoo 19 (1 process, threaded, 1 cron thread -- workers = 0)
   │
   ▼
PostgreSQL 17 (shared_buffers 64M, work_mem 1M, max_connections 20, no parallelism)

RAM 512 MB + zram 256 MB (zstd) + 1 GB disk swap, swappiness 100
```

Session/user responses are never proxy-cached (only static assets), so users
never see each other's data.

## Quickstart (on the Vultr VM)

```bash
sudo apt update && sudo apt install -y git
sudo git clone <your-repo-url> /opt/odoo-512mb
cd /opt/odoo-512mb
sudo ./deploy.sh
```

First run takes ~10–20 min (apt, Odoo source, DB + module init). Afterwards:

- Odoo: `https://<server-ip>/web/login` (self-signed cert — accept the warning)
- Default install: base, contacts, discuss, calendar, crm, sale_management, project

To change the module set later: edit `MODULES` in `deploy.sh`, then
`rm /var/lib/odoo/.initialized` and re-run `sudo ./deploy.sh` (re-runs `-i` on
the existing DB as an update). The marker file is what makes module init
run exactly once; it also lets the deploy heal a crashed first run.

## What the deploy does

| # | Step | Config source (repo → OS) |
|---|------|---------------------------|
| 1 | Install packages (nginx, postgresql-17, zram-tools, python3 deps, fonts) | — |
| 2 | Disable cups/bluetooth/avahi/ModemManager/rpcbind | — |
| 3 | Sysctl (swappiness 100), journald cap 50M | `configs/sysctl.conf` → `/etc/sysctl.d/99-odoo.conf`<br>`configs/journald.conf` → `/etc/systemd/journald.conf.d/99-odoo.conf` |
| 4 | zram 256M (zstd, prio 100) + 1G swapfile (prio 10) | `configs/zramswap` → `/etc/default/zramswap` |
| 5 | PostgreSQL tuning, restart, create `odoo` superuser | `configs/postgresql.conf` → `/etc/postgresql/17/main/postgresql.conf` |
| 6 | Odoo 19 source at pinned commit → `/opt/odoo/odoo`, venv over Debian python3 packages | — |
| 7 | `odoo` OS user, `/var/lib/odoo`, `/etc/odoo` | `configs/odoo.conf` → `/etc/odoo/odoo.conf` |
| 8 | Create `odoo` DB + init modules (first run only) | — |
| 9 | Systemd unit | `configs/odoo.service` → `/etc/systemd/system/odoo.service` |
| 10 | Nginx vhost + self-signed cert | `configs/nginx-odoo.conf` → `/etc/nginx/sites-{available,enabled}/odoo.conf` |
| 11 | Daily backup timer (04:30, keep 7) | `configs/backup.{service,timer}` → `/etc/systemd/system/`<br>`scripts/backup.sh` → `/usr/local/bin/odoo-backup` |

## Why source, not the official .deb

Odoo's nightly `.deb` for 19.0 depends on `python3-pypdf2`, which Debian 13
removed (replaced by `python3-pypdf`). The Odoo 19 `requirements.txt`
explicitly carries Debian 13 / Python 3.13 pins (`# (Trixie)`), so the
supported path is: Debian packages for everything apt can provide + a venv
(`--system-site-packages`) with Odoo's pinned `requirements.txt` on top.

Odoo is pinned to a specific commit (currently `9a272ea…`, 2026-09-19).
Bump `ODOO_COMMIT` in `deploy.sh` deliberately when you want an update.

## Database auth

No passwords anywhere. Odoo runs as OS user `odoo` and connects over the
Unix socket; Debian's stock `pg_hba.conf` uses `peer` auth on the socket, so
pg maps it to the database superuser `odoo` (`createuser -s odoo`).

## Editing config

```bash
# change something in configs/, then:
sudo ./deploy.sh          # idempotent re-apply (apt, pg restart, nginx -t, ...)
# or for nginx only:
sudo nginx -s reload
```

After the first deploy the repo is root-owned (configs are `root:odoo 640`) —
edit with `sudo`.

`admin_passwd` in `configs/odoo.conf` is a placeholder (`__GENERATE__`) that
the first deploy replaces with a random value. It is the web master password
used if you ever create/drop databases from the UI — keep it or change it
in the repo file.

## Real domain / Your own certificate

**Bring your own cert** (commercial, Cloudflare, internal CA, …): the vhost
reads fixed paths, so just place your files there and reload. Deploy never
overwrites an existing key:

```bash
sudo cp your-fullchain.pem /etc/nginx/ssl/odoo.crt
sudo cp your-private.key  /etc/nginx/ssl/odoo.key
sudo chmod 600 /etc/nginx/ssl/odoo.key
sudo nginx -s reload
```

(Otherwise deploy generates a self-signed pair on first run — that's the
default, not a barrier.)

### Let's Encrypt

The vhost already serves `/.well-known/acme-challenge/` from `/var/www/html`:

```bash
sudo apt install -y certbot
sudo certbot certonly --webroot -w /var/www/html -d yourdomain.com
sudo ln -sf /etc/letsencrypt/live/yourdomain.com/fullchain.pem /etc/nginx/ssl/odoo.crt
sudo ln -sf /etc/letsencrypt/live/yourdomain.com/privkey.pem /etc/nginx/ssl/odoo.key
sudo nginx -s reload
# certbot renew renews in place; the symlinks keep working
sudo systemctl enable certbot.timer    # auto-renewal
```

## Backup / restore

`/var/backups/odoo` holds daily `pg_dump -Fc` dumps + compressed filestore
(keep 7; tune with `KEEP`). **Copy them off the VM** — a single 10 GB disk is
not a backup strategy.

```bash
# restore
sudo -u postgres pg_restore -d odoo --jobs=2 /var/backups/odoo/odoo_odoo_*.dump
tar -C /var/lib -xzf /var/backups/odoo/odoo_filestore_*.tgz
sudo systemctl restart odoo
```

## Monitoring / troubleshooting

```bash
journalctl -u odoo -e                 # odoo logs (warn level by default)
journalctl -u postgresql -e           # postgres logs
systemd-cgtop                         # live memory per service
free -h; zramctl; swapon --show       # memory profile
systemctl list-timers odoo-backup.timer
```

Memory is intentionally tight: normal use fits in RAM, spikes fall to zram
then disk swap. If `systemd-cgtop` shows Odoo constantly in swap, first reduce
workload (scheduled actions in Settings → Technical), then consider
`MemoryMax=512M` in `configs/odoo.service` — deliberately not set by default.

## What is deliberately NOT here

Prefork workers, pgbouncer, redis/memcached, elasticsearch, tmpfs caches,
full-page proxy caching, debug logging, OOM watchdog scrips. 4 users on
Projects do not need any of them, and each would cost RAM this box does not
have.