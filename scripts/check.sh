#!/usr/bin/env bash
#
# Pre-flight check for this repo: shell syntax, shellcheck, systemd unit files.
# Costs a second and catches the typos that would otherwise be found by the live
# box, after the irreversible steps (apt, PG restart, symlink sweep) are done.
#
# Usage:  ./scripts/check.sh
#
# Deliberately not checked here: `nginx -t` (deploy.sh runs it against the real
# config anyway) and anything that needs the target VM.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

status=0
step() { printf '\n\033[1;32m==> %s\033[0m\n' "$1"; }

step "bash syntax"
for f in deploy.sh scripts/*.sh; do
  bash -n "$f" || status=1
done

step "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning deploy.sh scripts/*.sh || status=1
else
  echo "skipped: shellcheck not installed (apt install shellcheck)"
fi

step "systemd units"
if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify configs/*.service configs/*.timer || status=1
else
  echo "skipped: systemd-analyze not available (not a systemd host)"
fi

step "justfile"
if command -v just >/dev/null 2>&1; then
  just --fmt --check --justfile justfile || status=1
else
  echo "skipped: just not installed (apt install just)"
fi

step "result"
if [ "$status" -eq 0 ]; then
  echo "all checks passed"
else
  echo "CHECKS FAILED" >&2
fi
exit "$status"
