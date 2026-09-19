#!/usr/bin/env bash
#
# Daily Odoo backup: PostgreSQL dump (custom format) + filestore tarball.
# Keeps the $KEEP newest of each. Output: /var/backups/odoo
# Runs daily 04:30 via odoo-backup.timer (symlinked from this repo).
#
# Restore, e.g. (< is opened by root, because the dump is root-only 600):
#   sudo -u postgres pg_restore -d odoo < /var/backups/odoo/odoo_odoo_*.dump
#   sudo tar -C /var/lib -xzf /var/backups/odoo/odoo_filestore_*.tgz
#
set -euo pipefail

umask 077   # dumps and tarballs are 600/700 root-only: they contain all data

BACKUP_DIR=/var/backups/odoo
KEEP=${KEEP:-7}
STAMP=$(date +%Y%m%d_%H%M%S)

# /etc/odoo/odoo.conf owns the database name (deploy.sh renders it from the
# repo). No fallback value here: if the name cannot be read the backup must
# fail, not silently dump -- and then prune -- some other database.
DB=$(awk -F' = ' '/^db_name/{print $2}' /etc/odoo/odoo.conf)
[ -n "$DB" ] || { echo "no db_name in /etc/odoo/odoo.conf, refusing to guess" >&2; exit 1; }

mkdir -p "$BACKUP_DIR"
cd "$BACKUP_DIR"

DUMP="odoo_${DB}_${STAMP}.dump"
PARTIAL="$DUMP.partial"

# Dump to .partial, prove the archive reads back, then publish it under the
# final name: a truncated dump (killed timer, full disk, failed connection)
# never ends up looking like a backup.
# shellcheck disable=SC2024 # root's shell owns the redirect target on purpose:
# pg_dump runs as postgres but cannot write into this root-only 0700 directory.
sudo -u postgres pg_dump -Fc "$DB" > "$PARTIAL"
pg_restore -l "$PARTIAL" >/dev/null
mv "$PARTIAL" "$DUMP"

if [ -d /var/lib/odoo/filestore ]; then
  tar -C /var/lib -czf "odoo_filestore_${STAMP}.tgz" odoo/filestore
fi

# prune oldest, per artifact (only reached once the new backup is complete)
ls -1t "odoo_${DB}_"*.dump 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
ls -1t 'odoo_filestore_'*.tgz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f

echo "backup ok: $DB ($STAMP) -> $BACKUP_DIR"
