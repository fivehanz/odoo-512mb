# Odoo 19 on a 512 MB Debian 13 VM.
#
# Thin wrappers around deploy.sh and scripts/ -- run `just` to list them.
# Deploying, upgrading or remediating always means editing a file in this repo
# and re-running a recipe: nothing here edits the machine directly.

set shell := ["bash", "-uc"]

repo := justfile_directory()

# List the recipes
default:
    @just --list

# Static checks, before touching the VM: bash -n, shellcheck, systemd units
check:
    {{ repo }}/scripts/check.sh

# Deploy or re-apply the whole stack (idempotent; needs root)
deploy:
    sudo {{ repo }}/deploy.sh

# Health check of the running box (read-only, needs root)
doctor:
    sudo {{ repo }}/scripts/doctor.sh

# Upgrade path: pull the repo, then re-apply (ODOO_COMMIT pins Odoo itself)
upgrade:
    git -C {{ repo }} pull --ff-only
    sudo {{ repo }}/deploy.sh

# Run one backup now, then show the directory and the run log
backup:
    sudo systemctl start odoo-backup.service
    ls -lt /var/backups/odoo | head -5
    journalctl -u odoo-backup -n 10 --no-pager

# Backup directory, newest first
dumps:
    ls -lt /var/backups/odoo | head -20

# Follow a service log: just logs nginx
logs unit="odoo":
    journalctl -u {{ unit }} -f -n 100

# Timers (backups, apt) and when they fire next
timers:
    systemctl list-timers --all --no-pager

# RAM, zram, swap, and per-service memory
memory:
    free -h
    zramctl
    swapon --show
    systemd-cgtop -n 1

# Open a psql session as the admin (just psql, or: just psql mydb)
psql db="odoo":
    sudo -u postgres psql -w {{ db }}

# Certificate currently served: subject and expiry
cert:
    openssl x509 -in /etc/nginx/ssl/odoo.crt -noout -subject -issuer -enddate

# Validate the nginx config, then reload
reload:
    sudo nginx -t
    sudo systemctl reload nginx
