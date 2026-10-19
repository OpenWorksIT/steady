#!/usr/bin/env bash
# Saves everything in this test server (accounts, check-ins, results, watch data, settings)
# to one file, ready to load on another server with deploy/restore-data.sh.
#   ./export-data.sh [file]        default: steady-data-<date>.tar.gz here
# It contains patient information: keep it private, copy it with scp, delete it when done.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")"
compose() { docker compose --env-file .env -f compose.yml "$@"; }
OUT="${1:-steady-data-$(date +%Y%m%d-%H%M).tar.gz}"

compose up -d pocketbase >/dev/null
for _ in $(seq 1 30); do compose exec -T pocketbase wget -qO- http://127.0.0.1:8090/api/health >/dev/null 2>&1 && break; sleep 2; done

# SQLite's online backup: a consistent copy even while the server runs
umask 077
compose exec -T pocketbase sh -c '
  set -e
  rm -rf /tmp/snap && mkdir -p /tmp/snap
  for db in data.db auxiliary.db; do
    if [ -f "/pb/pb_data/$db" ]; then sqlite3 "/pb/pb_data/$db" ".backup /tmp/snap/$db"; fi
  done
  if [ -d /pb/pb_data/storage ]; then cp -r /pb/pb_data/storage /tmp/snap/; fi
  tar -C /tmp/snap -czf - . && rm -rf /tmp/snap
' > "$OUT"
echo "Saved $(du -h "$OUT" | cut -f1) to $PWD/$OUT"
echo "Copy it to the new server, e.g.: scp $OUT <you>@vps1.openworks.co.za:/tmp/"
