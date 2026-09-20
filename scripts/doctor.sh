#!/usr/bin/env bash
#
# Doctor: read-only health check of a deployed odoo-512mb box.
#
# Answers "is every part still running, and still the one we deployed?" --
# services, config drift, zram/swap, database auth, HTTP/TLS, certificates,
# backups (including a fresh one that actually reads back), security timers.
#
# Usage:  sudo ./scripts/doctor.sh
#
# Read-only: starts, stops and edits nothing. Exit status 1 if any check
# FAILed, 0 otherwise (warnings alone do not fail).

set -uo pipefail

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 2; }

command -v systemctl >/dev/null 2>&1 || die "no systemctl here -- run this on the Debian 13 VM"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PGDIR=/etc/postgresql/17/main
ODOO_CONF=/etc/odoo/odoo.conf
MASTER_PW=/etc/odoo/.admin_passwd
BACKUP_DIR=/var/backups/odoo
CRT=/etc/nginx/ssl/odoo.crt
DB_NAME=$(awk -F' = ' '/^db_name/{print $2}' "$ODOO_CONF" 2>/dev/null)
[ -n "${DB_NAME:-}" ] || die "no db_name in $ODOO_CONF -- run deploy.sh first"

fails=0
warns=0
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$*"; warns=$((warns + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fails=$((fails + 1)); }
info() { printf '       %s\n' "$*"; }

# ---------------------------------------------------------------------------
section "Services"
# ---------------------------------------------------------------------------
not_active=()
for u in odoo nginx postgresql fail2ban; do
  systemctl is-active --quiet "$u" || not_active+=("$u")
done
if [ "${#not_active[@]}" -eq 0 ]; then
  ok "active: odoo, nginx, postgresql, fail2ban"
else
  bad "not active: ${not_active[*]} (systemctl status <unit>, journalctl -u <unit>)"
fi

not_enabled=()
for u in odoo nginx zramswap ufw odoo-backup.timer apt-daily.timer apt-daily-upgrade.timer; do
  systemctl is-enabled --quiet "$u" || not_enabled+=("$u")
done
if [ "${#not_enabled[@]}" -eq 0 ]; then
  ok "enabled at boot: odoo, nginx, zramswap, ufw, odoo-backup.timer, apt-daily{,-upgrade}.timer"
else
  bad "not enabled at boot: ${not_enabled[*]}"
fi

# Scheduled actions, backup stamps and cert validation all depend on the clock.
if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]; then
  ok "clock is NTP-synchronised"
else
  warn "clock is not NTP-synchronised -- Odoo scheduled actions and TLS validation drift (timedatectl status)"
fi

# ---------------------------------------------------------------------------
section "Config drift (is /etc still this repo?)"
# ---------------------------------------------------------------------------
SYMLINKS=(
  "configs/sysctl.conf /etc/sysctl.d/99-odoo.conf"
  "configs/journald.conf /etc/systemd/journald.conf.d/99-odoo.conf"
  "configs/zramswap /etc/default/zramswap"
  "configs/postgresql.conf $PGDIR/postgresql.conf"
  "configs/pg_hba.conf $PGDIR/pg_hba.conf"
  "configs/odoo.service /etc/systemd/system/odoo.service"
  "configs/nginx-odoo.conf /etc/nginx/sites-available/odoo.conf"
  "configs/nginx-odoo.conf /etc/nginx/sites-enabled/odoo.conf"
  "configs/backup.service /etc/systemd/system/odoo-backup.service"
  "configs/backup.timer /etc/systemd/system/odoo-backup.timer"
  "scripts/backup.sh /usr/local/bin/odoo-backup"
  "configs/fail2ban-jail.local /etc/fail2ban/jail.local"
  "configs/fail2ban-filter-odoo.conf /etc/fail2ban/filter.d/odoo-login.conf"
  "configs/apt-20auto-upgrades /etc/apt/apt.conf.d/20auto-upgrades"
)
drifted=()
for pair in "${SYMLINKS[@]}"; do
  rel=${pair%% *}
  live=${pair##* }
  # resolve both sides: the clone itself may be reached through a symlink
  [ "$(readlink -f "$live" 2>/dev/null)" = "$(readlink -f "$REPO/$rel")" ] || drifted+=("$live")
done
if [ "${#drifted[@]}" -eq 0 ]; then
  ok "all ${#SYMLINKS[@]} managed configs point into $REPO"
else
  bad "not symlinked to this repo: ${drifted[*]}"
  info "fix: sudo ./deploy.sh   (or edit the file in the repo and re-run)"
fi

# odoo.conf is rendered rather than symlinked: it must be a real file, correctly
# owned, and must not still carry the placeholder.
if [ -L "$ODOO_CONF" ]; then
  warn "$ODOO_CONF is a symlink (an older deploy symlinked it); deploy.sh renders it now"
fi
expect="root:odoo:640"
got="$(stat -c '%U:%G:%a' "$ODOO_CONF" 2>/dev/null || echo missing)"
if [ "$got" = "$expect" ]; then
  ok "$ODOO_CONF is $expect"
else
  bad "$ODOO_CONF is $got, expected $expect"
fi
if grep -q '__GENERATE__' "$ODOO_CONF" 2>/dev/null; then
  bad "$ODOO_CONF still holds the placeholder password (deploy.sh did not render it)"
fi
got="$(stat -c '%U:%G:%a' "$MASTER_PW" 2>/dev/null || echo missing)"
[ "$got" = "$expect" ] && ok "$MASTER_PW is $expect" || bad "$MASTER_PW is $got, expected $expect"

dirty="$(git -C "$REPO" status --porcelain 2>/dev/null)"
if [ -z "$dirty" ]; then
  ok "repo working tree is clean ($(git -C "$REPO" rev-parse --short HEAD 2>/dev/null))"
else
  count="$(printf '%s\n' "$dirty" | grep -c .)"
  warn "repo has local modifications ($count paths), so a later 'git pull' would complain"
fi

# ---------------------------------------------------------------------------
section "Memory profile"
# ---------------------------------------------------------------------------
swap_show="$(swapon --show 2>/dev/null)"
if printf '%s' "$swap_show" | grep -q '^/dev/zram0'; then
  ok "zram0 active: $(printf '%s\n' "$swap_show" | awk '$1 == "/dev/zram0" {print $3 " priority " $5}')"
else
  bad "zram0 is not active -- with swappiness 100, reclaim lands on the disk swapfile"
  info "check: systemctl status zramswap; zramctl"
fi
if printf '%s' "$swap_show" | grep -q '^/swapfile'; then
  ok "disk swapfile active: $(printf '%s\n' "$swap_show" | awk '$1 == "/swapfile" {print $3 " priority " $5}')"
else
  warn "/swapfile is not active (1 GB of the documented profile is missing)"
fi

swappiness="$(sysctl -n vm.swappiness 2>/dev/null)"
[ "$swappiness" = "100" ] && ok "vm.swappiness = 100" || warn "vm.swappiness = ${swappiness:-?}, expected 100"

read -r used avail swap_used swap_total <<<"$(awk '
  /^MemTotal/{t=$2} /^MemAvailable/{a=$2} /^SwapTotal/{st=$2} /^SwapFree/{sf=$2}
  END{printf "%d %d %d %d", (t-a)/1024, a/1024, (st-sf)/1024, st/1024}' /proc/meminfo)"
info "RAM: ${used}M used, ${avail}M available | swap: ${swap_used}M used of ${swap_total}M"
[ "$avail" -lt 40 ] && warn "less than 40M RAM available -- expect swap churn"
if [ "${swap_total:-0}" -gt 0 ] && [ "$((swap_used * 100 / swap_total))" -ge 70 ]; then
  warn "swap ${swap_used}M of ${swap_total}M in use -- the box is paging; reduce workload or resize"
fi

root_use="$(df -P / | awk 'NR == 2 {gsub(/%/, "", $5); print $5}')"
case "$root_use" in
  ''|*[!0-9]*) warn "could not read / usage" ;;
  *) [ "$root_use" -ge 85 ] && warn "/ is ${root_use}% full (backups and Odoo filestore live here)" \
       || ok "/ usage ${root_use}%" ;;
esac

# ---------------------------------------------------------------------------
section "Database"
# ---------------------------------------------------------------------------
if sudo -u postgres psql -w -tAc 'SELECT 1' >/dev/null 2>&1; then
  ok "postgres accepts admin connections over the socket"
else
  bad "postgres refused the admin connection (check $PGDIR/pg_hba.conf, /var/log/postgresql)"
fi

role_super="$(sudo -u postgres psql -w -tAc "SELECT rolsuper FROM pg_roles WHERE rolname='odoo'" 2>/dev/null | tr -d ' ')"
[ "$role_super" = "t" ] && ok "role 'odoo' exists (superuser, as deploy created it)" \
  || bad "role 'odoo' is missing or not superuser (got '${role_super:-none}')"

if sudo -u postgres psql -w -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" 2>/dev/null | grep -q 1; then
  size="$(sudo -u postgres psql -w -tAc "SELECT pg_size_pretty(pg_database_size('$DB_NAME'))" 2>/dev/null | tr -d ' ')"
  ok "database '$DB_NAME' exists ($size)"
else
  bad "database '$DB_NAME' does not exist"
fi

if sudo -u postgres psql -w -h 127.0.0.1 -U odoo -d "$DB_NAME" -c 'SELECT 1' >/dev/null 2>&1; then
  bad "TCP login on 127.0.0.1 succeeded -- pg_hba.conf is not the repo's (should reject TCP)"
else
  ok "TCP auth rejected as configured (socket + peer only)"
fi

# ---------------------------------------------------------------------------
section "HTTP / TLS"
# ---------------------------------------------------------------------------
code="$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8069/web/login || true)"
[ "$code" = "200" ] && ok "Odoo answers directly on 127.0.0.1:8069 (200)" \
  || bad "Odoo on :8069 returned '${code:-no response}'"

code="$(curl -ks --max-time 5 -o /dev/null -w '%{http_code}' https://127.0.0.1/web/login || true)"
[ "$code" = "200" ] && ok "nginx answers on https://127.0.0.1 (200)" \
  || bad "nginx on :443 returned '${code:-no response}' (nginx -t, journalctl -u nginx)"

code="$(curl -ks --max-time 5 -o /dev/null -w '%{http_code}' "https://[::1]/web/login" || true)"
[ "$code" = "200" ] && ok "nginx answers on https://[::1] (200)" \
  || bad "nginx on [::1]:443 returned '${code:-no response}' (nginx -t, journalctl -u nginx)"

code="$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' http://127.0.0.1/web/login || true)"
case "$code" in
  301|302|308) ok "port 80 redirects to HTTPS ($code)" ;;
  *) warn "http://127.0.0.1/web/login returned '${code:-no response}', expected a redirect" ;;
esac

if [ -f "$CRT" ]; then
  subject="$(openssl x509 -in "$CRT" -noout -subject 2>/dev/null | sed 's/^subject=//')"
  enddate="$(openssl x509 -in "$CRT" -noout -enddate 2>/dev/null | cut -d= -f2)"
  if ! openssl x509 -in "$CRT" -noout -checkend $((21 * 86400)) >/dev/null 2>&1; then
    if openssl x509 -in "$CRT" -noout -checkend $((7 * 86400)) >/dev/null 2>&1; then
      warn "certificate expires within 21 days ($enddate) -- certbot renew, then nginx -s reload"
    else
      bad "certificate expires within 7 days ($enddate)"
    fi
  else
    ok "certificate valid ($subject, until $enddate)"
  fi
else
  bad "$CRT is missing -- nginx cannot serve TLS (re-run deploy.sh)"
fi

errs="$(journalctl -u odoo --since '-1h' -p err --no-pager 2>/dev/null | grep -c . || true)"
[ "${errs:-0}" -eq 0 ] && ok "no odoo errors in the last hour" \
  || warn "$errs odoo error line(s) in the last hour (journalctl -u odoo -p err --since -1h)"

# ---------------------------------------------------------------------------
section "Backups"
# ---------------------------------------------------------------------------
newest="$(ls -1t "$BACKUP_DIR"/odoo_"$DB_NAME"_*.dump 2>/dev/null | head -1)"
if [ -z "$newest" ]; then
  bad "no dump in $BACKUP_DIR (sudo systemctl start odoo-backup; journalctl -u odoo-backup)"
else
  age_h=$(( ($(date +%s) - $(stat -c %Y "$newest")) / 3600 ))
  size="$(du -h "$newest" | cut -f1)"
  if [ "$age_h" -gt 30 ]; then
    bad "newest dump is ${age_h}h old ($newest) -- the daily timer is not firing"
  elif [ "$age_h" -gt 26 ]; then
    warn "newest dump is ${age_h}h old (daily at 04:30; check systemctl list-timers)"
  else
    ok "newest dump is ${age_h}h old ($size, $(basename "$newest"))"
  fi
  if pg_restore -l "$newest" >/dev/null 2>&1; then
    ok "newest dump reads back (pg_restore -l)"
  else
    bad "newest dump is not readable by pg_restore -- treat the backup set as broken"
  fi
fi

partials="$(find "$BACKUP_DIR" -maxdepth 1 -name '*.partial' -printf '%f ' 2>/dev/null)"
if [ -n "$partials" ]; then
  warn "incomplete dump left behind: $partials"
  info "a run was killed mid-dump; check journalctl -u odoo-backup"
fi

if [ -d /var/lib/odoo/filestore ]; then
  fs_newest="$(ls -1t "$BACKUP_DIR"/odoo_filestore_*.tgz 2>/dev/null | head -1)"
  if [ -z "$fs_newest" ]; then
    warn "no filestore tarball in $BACKUP_DIR while /var/lib/odoo/filestore exists"
  else
    ok "filestore tarball present ($(du -h "$fs_newest" | cut -f1), $(basename "$fs_newest"))"
  fi
fi
info "dumps kept: $(ls -1 "$BACKUP_DIR"/odoo_"$DB_NAME"_*.dump 2>/dev/null | wc -l) (KEEP in configs/backup.service); next run: $(systemctl list-timers odoo-backup.timer --no-pager 2>/dev/null | sed -n 2p | awk '{print $1, $2, $3}')"
info "these are on the same disk as the data -- copy them off the VM"

# ---------------------------------------------------------------------------
section "Security"
# ---------------------------------------------------------------------------
if ! ufw status 2>/dev/null | grep -q '^Status: active'; then
  bad "ufw is not active (ufw status)"
elif [ "$(ufw status | grep -cE '^(22|80|443)/tcp +ALLOW')" -eq 3 ]; then
  ok "ufw active: 22, 80 and 443 allowed"
else
  bad "ufw active but 22/80/443 are not all allowed (ufw status)"
fi

if fail2ban-client status odoo-login >/dev/null 2>&1; then
  fresh="$(fail2ban-client status odoo-login 2>/dev/null | awk -F: '/Total failed/{gsub(/ /,"",$2); f=$2} /Currently banned/{gsub(/ /,"",$2); b=$2} END{print f+0, b+0}')"
  ok "jail 'odoo-login' is loaded (total failed: ${fresh%% *}, currently banned: ${fresh##* })"
else
  bad "jail 'odoo-login' is not active (fail2ban-client status; journalctl -u fail2ban)"
fi

read -r pending sec_pending <<<"$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null \
  | awk '/^Inst/{t++; if ($0 ~ /-Security/) s++} END{printf "%d %d", t+0, s+0}')"
if [ "${sec_pending:-0}" -gt 0 ]; then
  warn "${sec_pending} security update(s) pending (unattended-upgrades runs daily; journalctl -u unattended-upgrades)"
else
  ok "no pending security updates (${pending:-0} package update(s) available in total)"
fi

[ -f /var/run/reboot-required ] && warn "kernel/library update waiting for a reboot (README: reboots are manual)" \
  || ok "no reboot required"

# ---------------------------------------------------------------------------
printf '\n\033[1mSummary\033[0m\n'
if [ "$fails" -eq 0 ] && [ "$warns" -eq 0 ]; then
  echo "  healthy: every check passed"
elif [ "$fails" -eq 0 ]; then
  echo "  ok with $warns warning(s) -- nothing is broken, see above"
else
  echo "  $fails FAIL, $warns warning(s) -- see above; re-run: sudo ./deploy.sh"
fi
exit $(( fails > 0 ? 1 : 0 ))
