#!/usr/bin/env bash
#
# Deterministic Odoo 19 deploy for a 512 MB Debian 13 VM (Vultr $2.50 plan).
# Repo is the single source of truth: the config files below are symlinked from
# this repo into /etc (odoo.conf is the one exception -- it is rendered, so the
# master password never lands in git). Edit a file here, re-run, done.
#
# Usage:  sudo ./deploy.sh
#
# Idempotent: safe to re-run at any time. The slow, network-bound steps (apt,
# pip) are gated on marker files and skip themselves once satisfied; everything
# else re-runs every time because that is what makes an edit take effect.
# Run ./scripts/check.sh first -- it catches config typos in a second, before
# they reach the live box.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Tunables (edit here, keep in git)
# ---------------------------------------------------------------------------
ODOO_COMMIT=9a272ea4bffb245e9ec42190bff6b1c6fbefd548   # odoo/odoo 19.0 branch, 2026-09-19
PG_MAJOR=17                                            # Debian 13 ships PostgreSQL 17
MODULES=base,contacts,discuss,calendar,crm,sale_management,project
SWAPFILE=/swapfile
SWAP_SIZE=1G

# ---------------------------------------------------------------------------
# Fixed paths
# ---------------------------------------------------------------------------
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODOO_HOME=/opt/odoo
ODOO_SRC="$ODOO_HOME/odoo"
ODOO_VENV="$ODOO_HOME/venv"
ODOO_DATA=/var/lib/odoo
ODOO_CONF=/etc/odoo/odoo.conf

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# The database name has exactly one owner: configs/odoo.conf (db_name).
# scripts/backup.sh parses the rendered /etc file the same way, so there is no
# second literal that can drift out of sync.
DB_NAME=$(awk -F' = ' '/^db_name/{print $2}' "$REPO/configs/odoo.conf")
[ -n "$DB_NAME" ] || die "no db_name in $REPO/configs/odoo.conf"

[ "$(id -u)" -eq 0 ] || die "run as root: sudo ./deploy.sh"

. /etc/os-release
[ "${ID:-}" = debian ] || die "only Debian is supported (got '${ID:-}')"
[ "${VERSION_ID:-}" = 13 ] || echo "WARNING: intended for Debian 13, got ${VERSION_ID:-?}"

# ---------------------------------------------------------------------------
# 1. Packages. Odoo 19's nightly .deb requires python3-pypdf2, which was
#    removed from Debian 13, so we install Odoo from source (pinned commit)
#    into a venv that reuses Debian's python3-* packages.
# ---------------------------------------------------------------------------
log "Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  nginx postgresql-17 postgresql-client-17 \
  zram-tools git ca-certificates openssl curl sudo \
  python3-venv python3-pip lsb-base adduser \
  python3-asn1crypto python3-babel python3-cbor2 python3-chardet \
  python3-cryptography python3-dateutil python3-docutils python3-freezegun \
  python3-geoip2 python3-gevent python3-greenlet python3-idna python3-jinja2 \
  python3-libsass python3-lxml python3-lxml-html-clean python3-magic \
  python3-markupsafe python3-num2words python3-ofxparse python3-openpyxl \
  python3-openssl python3-passlib python3-pil python3-polib python3-psutil \
  python3-psycopg2 python3-pypdf python3-qrcode python3-reportlab \
  python3-requests python3-rjsmin python3-serial python3-stdnum python3-tz \
  python3-urllib3 python3-usb python3-vobject python3-werkzeug python3-xlrd \
  python3-xlsxwriter python3-xlwt python3-zeep python3-ldap python3-renderpm \
  fonts-dejavu-core fonts-inconsolata fonts-font-awesome \
  fonts-noto-core fonts-roboto-unhinted gsfonts libjs-underscore \
  fail2ban unattended-upgrades nftables

# ---------------------------------------------------------------------------
# 2. Drop unneeded services (every daemon matters on 512 MB)
# ---------------------------------------------------------------------------
log "Disabling unneeded services"
for s in cups bluetooth avahi-daemon ModemManager rpcbind; do
  systemctl disable --now "$s" 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# 3. Memory profile: sysctl, journald cap, zram, disk swap
# ---------------------------------------------------------------------------
log "Applying memory profile (sysctl / journald / zram / swap)"
ln -sfn "$REPO/configs/sysctl.conf" /etc/sysctl.d/99-odoo.conf
sysctl --system >/dev/null

mkdir -p /etc/systemd/journald.conf.d
ln -sfn "$REPO/configs/journald.conf" /etc/systemd/journald.conf.d/99-odoo.conf
systemctl restart systemd-journald

ln -sfn "$REPO/configs/zramswap" /etc/default/zramswap
systemctl restart zramswap 2>/dev/null || systemctl start zramswap
# Assert it rather than assume it: with swappiness 100 (configs/sysctl.conf) a
# zram that failed to start sends every reclaim straight to the 1 GB disk
# swapfile, which is worse than the stock configuration and otherwise silent.
swapon --show | grep -q '^/dev/zram0' || die "zram is not active (see: systemctl status zramswap, zramctl)"

if ! grep -q "$SWAPFILE" /etc/fstab; then
  echo "creating $SWAPFILE ($SWAP_SIZE)"
  fallocate -l "$SWAP_SIZE" "$SWAPFILE" 2>/dev/null \
    || dd if=/dev/zero of="$SWAPFILE" bs=1M count=$(( ${SWAP_SIZE%G} * 1024 )) status=none
  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE" >/dev/null
  echo "$SWAPFILE none swap sw,pri=10 0 0" >> /etc/fstab
fi
swapon "$SWAPFILE" 2>/dev/null || true   # no-op if already active

# ---------------------------------------------------------------------------
# 4. PostgreSQL: repo-owned postgresql.conf + pg_hba.conf, symlinked over the
#    stock files so tuning and auth are both pinned in git
# ---------------------------------------------------------------------------
log "Configuring PostgreSQL $PG_MAJOR"
PGDIR=/etc/postgresql/$PG_MAJOR/main
[ -d "$PGDIR" ] || die "postgresql $PG_MAJOR cluster directory missing: $PGDIR"
ln -sfn "$REPO/configs/postgresql.conf" "$PGDIR/postgresql.conf"
# Pins the auth model (peer on the socket, no TCP) instead of inheriting
# whatever Debian ships. A bad pg_hba.conf does not stop PostgreSQL from
# starting, only connecting, so this is verified below.
ln -sfn "$REPO/configs/pg_hba.conf" "$PGDIR/pg_hba.conf"
systemctl restart postgresql
sudo -u postgres psql -tAc 'SELECT 1' >/dev/null 2>&1 \
  || die "postgres refused the admin connection after config apply (check $PGDIR/pg_hba.conf, /var/log/postgresql)"

if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='odoo'" | grep -q 1; then
  sudo -u postgres createuser -s odoo
fi

# ---------------------------------------------------------------------------
# 5. Odoo from source at a pinned commit + venv over system python3 packages
# ---------------------------------------------------------------------------
log "Fetching Odoo 19 (pinned: ${ODOO_COMMIT:0:12})"
if [ ! -x "$ODOO_SRC/odoo-bin" ]; then
  mkdir -p "$ODOO_HOME"
  git clone --filter=blob:none --no-checkout https://github.com/odoo/odoo "$ODOO_SRC"
fi
# Always re-fetch the pinned commit so bumping ODOO_COMMIT takes effect on re-deploy
# (no-op when already at that commit).
git -C "$ODOO_SRC" fetch --depth 1 origin "$ODOO_COMMIT"
git -C "$ODOO_SRC" checkout -f FETCH_HEAD
[ -x "$ODOO_SRC/odoo-bin" ] || die "odoo source checkout failed"

if [ ! -x "$ODOO_VENV/bin/python" ]; then
  log "Creating venv (--system-site-packages reuses Debian python3-* packages)"
  python3 -m venv --system-site-packages "$ODOO_VENV"
fi

log "Installing Odoo python requirements (versions pinned in odoo/requirements.txt)"
# Gated on the requirements file's hash: a full pip resolve is minutes of
# network work on this box, and re-running it to change an nginx line is the
# difference between a 5-second and a 5-minute deploy. The hash changes whenever
# ODOO_COMMIT does, which is the only thing that can change the file.
REQ_MARKER="$ODOO_HOME/.requirements.sha256"
REQ_HASH=$(sha256sum "$ODOO_SRC/requirements.txt" | cut -d' ' -f1)
if [ ! -f "$REQ_MARKER" ] || [ "$(cat "$REQ_MARKER")" != "$REQ_HASH" ]; then
  "$ODOO_VENV/bin/pip" install --no-cache-dir -r "$ODOO_SRC/requirements.txt"
  echo "$REQ_HASH" > "$REQ_MARKER"
else
  echo "requirements unchanged (${REQ_HASH:0:12}), skipping pip"
fi

# ---------------------------------------------------------------------------
# 6. odoo user, data dirs, config (rendered from the repo, then symlink-free:
#    the live file is a real file so the master password never enters git)
# ---------------------------------------------------------------------------
log "Creating odoo user and directories"
id -u odoo >/dev/null 2>&1 \
  || useradd --system --home-dir "$ODOO_DATA" --create-home --shell /usr/sbin/nologin odoo
mkdir -p "$ODOO_DATA" /etc/odoo

# admin master password: rendered here, never in the repo. The placeholder in
# configs/odoo.conf stays a placeholder forever, so the tracked file never
# carries a secret, the working tree stays clean for `git pull`, and the deploy
# never chowns anything inside the clone.
rm -f "$ODOO_CONF"
if [ -f /etc/odoo/.admin_passwd ]; then
  ADMIN_PASSWD=$(cat /etc/odoo/.admin_passwd)      # keep it across re-deploys
else
  ADMIN_PASSWD=$(openssl rand -hex 24)
  printf '%s' "$ADMIN_PASSWD" > /etc/odoo/.admin_passwd
fi
sed "s|__GENERATE__|$ADMIN_PASSWD|" "$REPO/configs/odoo.conf" > "$ODOO_CONF"
chown root:odoo "$ODOO_CONF"
chmod 640 "$ODOO_CONF"
chown root:odoo /etc/odoo/.admin_passwd
chmod 640 /etc/odoo/.admin_passwd
chown -R odoo:odoo "$ODOO_DATA"

# ---------------------------------------------------------------------------
# 7. Create the database on first deploy (Odoo connects via unix socket,
#    peer auth as the OS user 'odoo' -- no password anywhere)
# ---------------------------------------------------------------------------
# Run module init exactly once, and heal a partially-initialized DB (e.g. a
# crashed first run). Delete /var/lib/odoo/.initialized to force a re-init after
# changing MODULES.
if [ ! -f "$ODOO_DATA/.initialized" ]; then
  if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
    log "Completing initialization of '$DB_NAME' (previous init was incomplete)"
  else
    log "Initializing database '$DB_NAME' with modules: $MODULES (several minutes)"
  fi
  sudo -u odoo "$ODOO_VENV/bin/python" "$ODOO_SRC/odoo-bin" \
    -c "$ODOO_CONF" -d "$DB_NAME" --without-demo=all -i "$MODULES" --stop-after-init
  touch "$ODOO_DATA/.initialized"
fi

# ---------------------------------------------------------------------------
# 8. systemd unit (symlinked)
# ---------------------------------------------------------------------------
log "Installing odoo systemd unit"
ln -sfn "$REPO/configs/odoo.service" /etc/systemd/system/odoo.service
systemctl daemon-reload
systemctl enable --now odoo

# ---------------------------------------------------------------------------
# 9. Nginx reverse proxy + TLS (self-signed by default; see README for LE)
# ---------------------------------------------------------------------------
log "Configuring nginx (TLS terminated at nginx)"
mkdir -p /etc/nginx/ssl /var/www/html
if [ ! -f /etc/nginx/ssl/odoo.key ]; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -subj "/CN=odoo-512mb" \
    -keyout /etc/nginx/ssl/odoo.key -out /etc/nginx/ssl/odoo.crt
  chmod 600 /etc/nginx/ssl/odoo.key
fi
ln -sfn "$REPO/configs/nginx-odoo.conf" /etc/nginx/sites-available/odoo.conf
ln -sfn "$REPO/configs/nginx-odoo.conf" /etc/nginx/sites-enabled/odoo.conf
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx
systemctl reload nginx

# ---------------------------------------------------------------------------
# 10. Backups: daily DB dump + filestore tarball (keep 7)
# ---------------------------------------------------------------------------
log "Installing backup timer"
ln -sfn "$REPO/scripts/backup.sh" /usr/local/bin/odoo-backup
ln -sfn "$REPO/configs/backup.service" /etc/systemd/system/odoo-backup.service
ln -sfn "$REPO/configs/backup.timer" /etc/systemd/system/odoo-backup.timer
chmod +x "$REPO/scripts/backup.sh"
systemctl daemon-reload
systemctl enable --now odoo-backup.timer

# ---------------------------------------------------------------------------
# 11. Security: automatic Debian 13 security updates + fail2ban for the
#     Odoo login page (nftables ban, driven by nginx access log -- see the
#     filter for why 200/422 on POST /web/login == failed login)
# ---------------------------------------------------------------------------
log "Configuring security (unattended-upgrades + fail2ban)"
ln -sfn "$REPO/configs/apt-20auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer

ln -sfn "$REPO/configs/fail2ban-jail.local" /etc/fail2ban/jail.local
ln -sfn "$REPO/configs/fail2ban-filter-odoo.conf" /etc/fail2ban/filter.d/odoo-login.conf
systemctl enable --now fail2ban
systemctl restart fail2ban

# ---------------------------------------------------------------------------
# 12. Health checks + summary
# ---------------------------------------------------------------------------
log "Health checks"
for i in 1 2 3 4 5; do
  curl -fsS -o /dev/null http://127.0.0.1:8069/web/login && break
  [ "$i" -eq 5 ] && die "odoo not answering on :8069"
  sleep 2
done
curl -kfsS -o /dev/null https://127.0.0.1/web/login || die "nginx https not answering"

# Assert the parts a 200 from Odoo does not prove: the jail that guards the
# login form, the timer that carries the backups, and one real backup run.
# A backup nobody has executed is not a backup.
fail2ban-client status odoo-login >/dev/null 2>&1 \
  || die "fail2ban jail 'odoo-login' is not active (fail2ban-client status)"
systemctl is-active --quiet odoo-backup.timer \
  || die "backup timer is not active (systemctl status odoo-backup.timer)"
systemctl start odoo-backup.service \
  || die "first backup failed (journalctl -u odoo-backup)"
ls -1 /var/backups/odoo/*.dump >/dev/null 2>&1 \
  || die "backup ran but produced no dump (journalctl -u odoo-backup)"

echo
echo "Deploy complete."
echo "  Odoo:          https://<server-ip>/          (login at /web/login)"
echo "  Database:      $DB_NAME        filestore: $ODOO_DATA"
echo "  Configs:       symlinked from $REPO into /etc (odoo.conf rendered) -- edit in the repo, re-run ./deploy.sh"
echo "  Backups:       daily 04:30 -> /var/backups/odoo (keep 7, see README for restore)"
echo "  Security:      unattended-upgrades (daily) + fail2ban (5 fails/10min -> 1h ban)"
echo "  Master passwd: /etc/odoo/.admin_passwd (same value in /etc/odoo/odoo.conf)"
echo "  TLS:           self-signed, see README for Let's Encrypt on a real domain"