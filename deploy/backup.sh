#!/usr/bin/env bash
# Nightly encrypted backup of Steady's data. Run from cron on the host, e.g.
#   15 1 * * *  /opt/steady/deploy/backup.sh /srv/backups/steady
# Needs: docker, age (https://age-encryption.org) and a recipient public key in
# deploy/secrets/backup.age.pub. Keep the private key OFF this server.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")"
DEST="${1:?usage: backup.sh <destination-dir>}"
KEEP_DAYS="${KEEP_DAYS:-30}"
RECIPIENT_FILE="secrets/backup.age.pub"
[ -f "$RECIPIENT_FILE" ] || { echo "Missing $RECIPIENT_FILE (an age public key)" >&2; exit 1; }
command -v age >/dev/null || { echo "Install age first" >&2; exit 1; }

mkdir -p "$DEST"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# SQLite's online backup gives a consistent copy while the server keeps running.
docker compose exec -T pocketbase sh -c '
  set -e
  rm -rf /tmp/snap && mkdir -p /tmp/snap
  for db in data.db auxiliary.db; do
    if [ -f "/pb/pb_data/$db" ]; then sqlite3 "/pb/pb_data/$db" ".backup /tmp/snap/$db"; fi
  done
  if [ -d /pb/pb_data/storage ]; then cp -r /pb/pb_data/storage /tmp/snap/; fi
  tar -C /tmp/snap -cf - . && rm -rf /tmp/snap
' > "$TMP/pb_data.tar"
age -R "$RECIPIENT_FILE" -o "$DEST/steady-$STAMP.tar.age" "$TMP/pb_data.tar"
find "$DEST" -name 'steady-*.tar.age' -mtime +"$KEEP_DAYS" -delete
echo "Backup written: $DEST/steady-$STAMP.tar.age"
