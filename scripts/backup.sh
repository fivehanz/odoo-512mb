#!/usr/bin/env bash
#
# Daily Odoo backup: PostgreSQL dump (custom format) + filestore tarball.
# Keeps the $KEEP newest of each. Output: /var/backups/odoo
# Runs daily 04:30 via odoo-backup.timer (symlinked from this repo).
#
# Restore, e.g.:
#   sudo -u postgres pg_restore -d odoo --jobs=2 /var/backups/odoo/odoo_odoo_*.dump
#   tar -C /var/lib -xzf /var/backups/odoo/odoo_filestore_*.tgz
#
set -euo pipefail

umask 077   # dumps and tarballs are 600/700 root-only: they contain all data

BACKUP_DIR=/var/backups/odoo
KEEP=${KEEP:-7}
DB=${DB:-$(awk -F' = ' '/^db_name/{print $2}' /etc/odoo/odoo.conf)}
DB=${DB:-odoo}
STAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$BACKUP_DIR"
cd "$BACKUP_DIR"

sudo -u postgres pg_dump -Fc "$DB" > "odoo_${DB}_${STAMP}.dump"

if [ -d /var/lib/odoo/filestore ]; then
  tar -C /var/lib -czf "odoo_filestore_${STAMP}.tgz" odoo/filestore
fi

# prune oldest, per artifact
ls -1t "odoo_${DB}_"*.dump 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
ls -1t 'odoo_filestore_'*.tgz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f

echo "backup ok: $DB ($STAMP) -> $BACKUP_DIR"