# odoo-512mb

Deterministic Odoo 19 deployment for a **512 MB RAM / Debian 13** VM (Vultr
$2.50 plan), aimed at ~4 users, primarily Projects.

One command deploys the whole stack. Every config lives in this repo and is
**symlinked** into the OS (`odoo.conf` is rendered instead, see below) — the
repo, not the live machine, is the source of truth. Re-run the deploy after any
edit; it is idempotent.

## Architecture

```text
Internet
   │ :443 (nginx TLS, self-signed by default)
   ▼
Nginx ── gzip ── disk asset cache (/web/assets/ only: content-hashed URLs, 30d)
   │
   ▼
Odoo 19 (1 process, threaded, 1 cron thread -- workers = 0)
   │
   ▼
PostgreSQL 17 (shared_buffers 64M, work_mem 1M, max_connections 20, no parallelism)

RAM 512 MB + zram 256 MB (zstd) + 1 GB disk swap, swappiness 100
```

Only content-hashed `/web/assets/` URLs are proxy-cached. Unhashed and
user-owned paths (`/web/static/`, `/web/image/`, `/web/content/`, sessions) are
passed straight through: nginx's cache key has no session component, so caching
them would serve one user's response to the next requester.

## Quickstart (on the Vultr VM)

Three prerequisites, then one command. `git` is how the repo gets there; `just`
and `shellcheck` only exist to make the recipes and `just check` work — the
deploy installs everything else it needs, and deliberately does not install the
tools you use to drive it (you would have to have them to start it).

```bash
sudo apt update
sudo apt install -y git just shellcheck
sudo git clone <your-repo-url> /opt/odoo-512mb
cd /opt/odoo-512mb
just check            # static: bash -n, shellcheck, systemd unit syntax
just deploy           # or: sudo ./deploy.sh if you would rather not use just
```

`just` is optional: every recipe is a one-line wrapper (see
[Task shortcuts](#task-shortcuts-just)). Without it, run the scripts by hand.

First run takes ~10–20 min (apt, Odoo source, DB + module init). Re-runs are
seconds: apt and `pip install -r requirements.txt` are gated on marker files and
skip themselves unless the pinned commit changed (`/opt/odoo/.requirements.sha256`).
The symlink sweep, `nginx -t`, `daemon-reload` and the service restarts always run —
that is what makes an edit take effect.

Afterwards:

- Odoo: `https://<server-ip>/web/login` (self-signed cert — accept the warning)
- Default install: base, contacts, mail, calendar, crm, project

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
| 4 | zram 256M (zstd, prio 100) + 1G swapfile (prio 10), asserted active | `configs/zramswap` → `/etc/default/zramswap` |
| 5 | PostgreSQL tuning + pinned auth model (`peer` on the socket, TCP rejected), restart, create `odoo` superuser | `configs/postgresql.conf` → `/etc/postgresql/17/main/postgresql.conf`<br>`configs/pg_hba.conf` → `/etc/postgresql/17/main/pg_hba.conf` |
| 6 | Odoo 19 source at pinned commit → `/opt/odoo/odoo`, venv over Debian python3 packages | — |
| 7 | `odoo` OS user, `/var/lib/odoo`, `/etc/odoo`; `odoo.conf` **rendered** (not symlinked) so the master password stays out of git | `configs/odoo.conf` → `/etc/odoo/odoo.conf` (rendered) |
| 8 | Create `odoo` DB + init modules (first run only) | — |
| 9 | Systemd unit | `configs/odoo.service` → `/etc/systemd/system/odoo.service` |
| 10 | Nginx vhost + self-signed cert | `configs/nginx-odoo.conf` → `/etc/nginx/sites-{available,enabled}/odoo.conf` |
| 11 | Fail2ban (Odoo-login brute force, nftables) + unattended-upgrades (Debian security updates, no auto-reboot) | `configs/fail2ban-jail.local` → `/etc/fail2ban/jail.local`<br>`configs/fail2ban-filter-odoo.conf` → `/etc/fail2ban/filter.d/odoo-login.conf`<br>`configs/apt-20auto-upgrades` → `/etc/apt/apt.conf.d/20auto-upgrades` |
| 12 | Daily backup timer (04:30, keep 7) | `configs/backup.{service,timer}` → `/etc/systemd/system/`<br>`scripts/backup.sh` → `/usr/local/bin/odoo-backup` |

## Task shortcuts (just)

`just` with no argument lists them. Every recipe is a one-line wrapper around a
script in this repo — nothing lives only in the justfile.

| Recipe | Does |
|--------|------|
| `just deploy` | Full deploy / re-apply (`sudo ./deploy.sh`) |
| `just check` | Static checks of this repo; needs no VM access |
| `just doctor` | Health check of the running box (read-only, needs root) |
| `just upgrade` | `git pull --ff-only`, then re-apply |
| `just backup` | Run one backup now, show the directory and the run log |
| `just dumps` | Backup directory, newest first |
| `just logs [unit]` | Follow a unit's journal (`just logs nginx`) |
| `just timers` | Backup and apt timers, with the next run |
| `just memory` | `free`, `zramctl`, `swapon`, `systemd-cgtop` |
| `just psql [db]` | Admin psql session |
| `just cert` | Subject, issuer and expiry of the certificate in use |
| `just reload` | `nginx -t`, then reload |

### check vs doctor

`check` never touches the machine. It lints the repo (`bash -n`, `shellcheck`,
`systemd-analyze verify`), so a typo fails in a second instead of mid-deploy —
after apt has run and PostgreSQL has been restarted. It is also the CI job.

`doctor` only reads the machine, and answers the other half: is everything
deployed *still* deployed and working? Services active and enabled, every
managed config still a symlink into this repo (drift), `odoo.conf` rendered with
the right owner/mode and no placeholder left, zram and swap priorities,
`vm.swappiness`, database role and reachability, TCP auth still rejected,
HTTP/TLS on 80/8069/443, certificate expiry, newest backup fresh *and* readable
by `pg_restore`, stray `.partial` dumps, filestore tarball, disk headroom,
fail2ban jail, pending security updates, reboot-required. Exit status is 1 if
anything FAILed; warnings alone do not fail.

## Why source, not the official .deb

Odoo's nightly `.deb` for 19.0 depends on `python3-pypdf2`, which Debian 13
removed (replaced by `python3-pypdf`). The Odoo 19 `requirements.txt`
explicitly carries Debian 13 / Python 3.13 pins (`# (Trixie)`), so the
supported path is: Debian packages for everything apt can provide + a venv
(`--system-site-packages`) with Odoo's pinned `requirements.txt` on top.

Odoo is pinned to a specific commit (currently `9a272ea…`, 2026-09-19).
Bump `ODOO_COMMIT` in `deploy.sh` deliberately when you want an update.

Node.js is deliberately **not** installed: Odoo 19's docs list it only for
right-to-left interface languages (Arabic/Hebrew, via the `rtlcss` npm
package). If you need RTL: `apt-get install nodejs npm && npm install -g rtlcss`.

## Database auth

No passwords anywhere. Odoo runs as OS user `odoo` and connects over the
Unix socket; `configs/pg_hba.conf` (repo-managed, see Security) uses `peer`
auth on the socket, so pg maps it to the database superuser `odoo`
(`createuser -s odoo`).

## Editing config

```bash
just check                # 1 s: bash -n + shellcheck + systemd-analyze verify
# change something in configs/, then:
just deploy               # re-apply (symlinks, pg restart, nginx -t, ...)
just doctor               # confirm the box came back healthy
# or for nginx only:
just reload
```

Run `just check` before pushing: `deploy.sh` is root-privileged, and the checks
it does itself run *after* the irreversible steps (apt, PostgreSQL restart,
symlink sweep). A typo caught by `check` never reaches the VM; a typo that gets
past it is caught by `doctor` a minute later instead of by a user.

The clone is left alone — deploy chowns and chmods only the files it installs
into `/etc`, never the repo, so `git pull` works with no local modifications.

`admin_passwd` in `configs/odoo.conf` is a permanent placeholder
(`__GENERATE__`). Each deploy renders the file into `/etc/odoo/odoo.conf` with a
random master password, keeping it in `/etc/odoo/.admin_passwd` across re-runs.
The placeholder never leaves the repo, so no secret is ever committed. The
password only matters if you ever set `list_db = True`; with the default
`list_db = False` the web database manager is unreachable, which is why nothing
else depends on it.

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
(keep 7; tune with `KEEP`). Each dump is written as `.partial`, checked with
`pg_restore -l`, and only then renamed — a killed timer or a full disk can no
longer leave a truncated file that looks like a backup. The unit has
`TimeoutStartSec=infinity`, because a database that outgrows systemd's 90 s
default would otherwise be SIGTERMed mid-dump. `journalctl -u odoo-backup` shows
the result of each run; **copy the dumps off the VM** — a single 10 GB disk is
not a backup strategy.

Restore onto a rebuilt box (the role and database do not exist yet):

```bash
sudo -u postgres createuser -s odoo
sudo -u postgres createdb -O odoo odoo
sudo -u postgres pg_restore -d odoo < /var/backups/odoo/odoo_odoo_<stamp>.dump
sudo tar -C /var/lib -xzf /var/backups/odoo/odoo_filestore_<stamp>.tgz
sudo systemctl restart odoo
```

The `<` matters: the dumps are root-only `600` in a `700` directory, so root
opens the file and `pg_restore` (running as `postgres`) reads the descriptor it
inherits. Reading from stdin also rules out `--jobs=N`; if you want parallel
restore on a large dump, copy it somewhere postgres can read first
(`sudo install -o postgres -m 600 <dump> /var/lib/postgresql/`).

Restoring over an existing database, add `--clean --if-exists` to `pg_restore`.

## Security

- **unattended-upgrades** runs Debian security updates daily (apt timers). No
  automatic reboots — a kernel update waits for a manual `reboot`.
- **Database auth** is pinned in `configs/pg_hba.conf`: `peer` on the Unix
  socket, TCP rejected. A package upgrade can no longer change the auth model
  out from under the deploy.
- **fail2ban** watches nginx access logs for failed `POST /web/login`
  (a failure re-renders with HTTP 200, a success redirects 302):
  `fail2ban-client status odoo-login`, and `journalctl -u fail2ban` to see bans.
  The filter lives in the repo too, so log lines can't drift from the repo.
  SSH brute-force protection comes from Debian's stock
  `/etc/fail2ban/jail.d/defaults-debian.conf` (the `sshd` jail) — intentionally
  not duplicated here.
- RAM cost: fail2ban is a Python daemon, ~30–40 MB idle. If you ever want it
  gone, the lighter native defense is nginx `limit_req` on `/web/login`
  (zero extra daemons) — not included because fail2ban was the ask.
- **No host firewall, by design.** Only 22 (SSH), 80 and 443 are reachable;
  Odoo and PostgreSQL bind to loopback, and `nftables` is installed solely as
  fail2ban's ban backend. If you would rather enforce that in the kernel,
  Vultr's firewall is the lower-risk place; a local ruleset must keep SSH open:

  ```bash
  nft add table inet filter
  nft add chain inet filter input '{ type filter hook input priority 0; policy drop; }'
  nft add rule inet filter input ct state established,related accept
  nft add rule inet filter input tcp dport '{ 22, 80, 443 }' accept
  ```

Left stock on purpose: `/etc/apt/apt.conf.d/50unattended-upgrades` (which update
origins are trusted) and the fail2ban `sshd` jail above. Only
`configs/apt-20auto-upgrades` is repo-managed, because that is where the
"run daily, never reboot" policy lives.

Tune bans in `configs/fail2ban-jail.local` (maxretry / findtime / bantime).

## Monitoring / troubleshooting

The deploy asserts these before it prints "Deploy complete": Odoo and nginx
answering, zram active, the fail2ban `odoo-login` jail loaded, the backup timer
enabled, and one real backup run (dump written and proven readable).
`just doctor` re-checks that and more (config drift, TLS expiry, database auth,
disk headroom, pending security updates); re-check by hand when something feels
wrong:

```bash
fail2ban-client status odoo-login    # jail active and reading /var/log/nginx/access.log
zramctl; swapon --show               # zram0 first, disk swapfile second
systemctl list-timers odoo-backup.timer
ls -l /var/backups/odoo              # dump + filestore tarball, 600, root-owned
journalctl -u odoo-backup -n 20      # run one now: sudo systemctl start odoo-backup
```

```bash
journalctl -u odoo -e                 # odoo logs (warn level by default)
journalctl -u postgresql -e           # postgres logs
systemd-cgtop                         # live memory per service
free -h; zramctl; swapon --show       # memory profile
```

Memory is intentionally tight: normal use fits in RAM, spikes fall to zram
then disk swap. If `systemd-cgtop` shows Odoo constantly in swap, first reduce
workload (scheduled actions in Settings → Technical), then consider
`MemoryMax=512M` in `configs/odoo.service` — deliberately not set by default.

## Capacity: when this box stops being usable

It runs out of **disk** long before RAM or CPU, and the backup retention is what
gets there first: 7 filestore tarballs live on the same disk as the data.

| Part | Rough size |
|------|-----------|
| Debian 13 + installed packages | 1.5–2 GB |
| Odoo source (blobless clone) + venv | 0.7–1 GB |
| `/var/backups/odoo` | 7 DB dumps (small) + **7 compressed copies of the filestore** |
| live database + filestore | 1× filestore |

Compressed text attachments are roughly a third of their size, so the backup set
costs about 2.5–3× the filestore. On the 10 GB disk this plan ships (check
`df -h /`), with ~2.5 GB taken by the OS and the app, the filestore ceiling is
in the region of **1 GB**. At four users on Projects that is years; if people
start scanning PDFs and photos it is months. `just doctor` reports `/` usage,
warns at 85%, and fails if the newest dump is older than 30 h.

When it fills up, in order of preference:

1. Lower retention: `Environment=KEEP=3` in `configs/backup.service`, then
   `just deploy`. Keeps three days instead of seven.
2. Get the dumps off the box and delete the old ones — the offsite copy you
   should be making anyway.
3. Grow the volume (Vultr lets you resize the disk; then resize the filesystem
   and reboot).

RAM and CPU degrade rather than die: zram fills, then disk swap, and in the worst
case the OOM killer takes Odoo (`OOMScoreAdjust=200` makes sure it is Odoo and
not PostgreSQL) — users see slowness and 502s, and Odoo comes back on its own.
If `just doctor` repeatedly reports swap over 70%, move to the 1 GB plan; that
is a stop-and-restart resize, nothing to reinstall.

## Maintenance calendar

Automatic, no action: Debian security updates daily (unattended-upgrades),
backup at 04:30, fail2ban online, TLS terminated by nginx.

Monthly, about five minutes:

```bash
just doctor          # is it still the deployment we made?
just backup          # known-good dump before you change anything
just upgrade         # only when you want a newer Odoo (see ODOO_COMMIT)
```

Reboot when:

- `just doctor` says a reboot is required, i.e. `/var/run/reboot-required`
  exists (`cat /var/run/reboot-required.pkgs` shows what wants it). On stable
  that is roughly 1–2 times a month — kernel, libc, openssl, systemd. Reboots
  are deliberately manual so they never land mid-workday: `sudo systemctl
  reboot` and re-run `just doctor` afterwards.
- PostgreSQL was upgraded by unattended-upgrades and `just doctor` fails the
  admin-connection check (`sudo systemctl restart postgresql` is usually enough).
- The box is paging constantly (`swap used` warning) and nothing else explains it.

Upgrade policy:

- **Debian**: patch and minor versions arrive automatically. A release upgrade
  (trixie → next) is a separate project and not needed for years — Trixie is the
  current stable.
- **PostgreSQL 17**: patch releases via apt. A *major* upgrade would mean
  `pg_upgradecluster`; nothing to plan for on Trixie.
- **Odoo**: pinned to `ODOO_COMMIT` on purpose — `git pull` and `just upgrade`
  upgrade the *deployment*, not Odoo. Bump the commit (monthly, or the same day
  for a security advisory), always after `just backup`, then `just doctor`.
  Never edit the installed copy under `/opt/odoo`: the next deploy reverts it.

Still missing, and the two things worth deciding before calling this fully
production-grade:

- **Offsite backups.** `just backup` writes to the same disk as the data. Add a
  push to object storage or another host (rclone/rsync in a second timer) — that
  also removes the disk ceiling above.
- **A real certificate.** Self-signed means every user clicks through a browser
  warning, which trains exactly the wrong reflex. Do the Let's Encrypt step
  below before people start using it. Optional: a free HTTP check
  (UptimeRobot-style) on `https://<ip>/web/login` so a dead Odoo is noticed
  without anyone running `just doctor`.

## What is deliberately NOT here

Prefork workers, pgbouncer, redis/memcached, elasticsearch, tmpfs caches,
full-page proxy caching, debug logging, OOM watchdog scrips. 4 users on
Projects do not need any of them, and each would cost RAM this box does not
have.