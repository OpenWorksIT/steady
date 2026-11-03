#!/usr/bin/env bash
# Replaces ALL of this server's Steady data with a file from export-data.sh (.tar.gz) or a
# decrypted backup.sh backup (.tar):
#   age -d -i backup-key.txt steady-20261019T011500Z.tar.age > /tmp/steady.tar
#   sudo ./restore-data.sh /tmp/steady.tar [--keep-sessions]
# Accounts and settings come with it, so people sign in with the same email and password as
# before. First it keeps a copy of the data it replaces (encrypted, when
# secrets/backup.age.pub is there) in /var/backups/steady. Afterwards everyone is signed out
# (new token secrets, accounts.sh rotate-sessions): sessions from the restored copy, or from
# anyone else who has it, stop working. --keep-sessions skips that.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")"
FILE="${1:?usage: restore-data.sh <steady-data file> [--keep-sessions]}"
KEEP_SESSIONS=false
[ "${2:-}" = "--keep-sessions" ] && KEEP_SESSIONS=true
[ -f "$FILE" ] || { echo "No such file: $FILE" >&2; exit 1; }
FILE="$(realpath "$FILE")"
[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo ./restore-data.sh $FILE" >&2; exit 1; }
# export-data.sh writes gzip, backup.sh a plain tar (inside age): take either
Z=""
[ "$(head -c 2 "$FILE" | od -An -tx1 | tr -d ' \n')" = "1f8b" ] && Z="z"
# read the whole listing (grep -q would stop early and, with pipefail, fail the check on big files)
LIST="$(tar -t${Z}f "$FILE")" || { echo "$FILE can't be read as a tar file (incomplete copy, or still encrypted?)." >&2; exit 1; }
grep -q 'data.db$' <<<"$LIST" || { echo "$FILE doesn't look like Steady data (no data.db)." >&2; exit 1; }

read -r -p "This replaces ALL Steady data on this server with $(basename "$FILE"). Type yes to continue: " ok
[ "$ok" = yes ] || { echo "Nothing changed."; exit 1; }

# a copy of what's about to be replaced
SAFE_DIR=/var/backups/steady
install -d -m 700 "$SAFE_DIR"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
docker compose stop pocketbase
if [ -f secrets/backup.age.pub ] && command -v age >/dev/null; then
  SAFE="$SAFE_DIR/before-restore-$STAMP.tar.age"
  docker compose run --rm --no-deps -T -u 0 --entrypoint sh pocketbase -c 'tar -C /pb/pb_data -cf - .' \
    | age -R secrets/backup.age.pub -o "$SAFE"
else
  SAFE="$SAFE_DIR/before-restore-$STAMP.tar"
  ( umask 077; docker compose run --rm --no-deps -T -u 0 --entrypoint sh pocketbase -c 'tar -C /pb/pb_data -cf - .' > "$SAFE" )
  echo "Note: no secrets/backup.age.pub, so the copy of the old data is NOT encrypted: $SAFE (root only). Delete it once you're sure." >&2
fi
echo "The data being replaced is kept in $SAFE"

docker compose run --rm --no-deps -u 0 --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
  -e Z="$Z" -v "$FILE:/restore.tar:ro" --entrypoint sh pocketbase -c '
    set -e
    find /pb/pb_data -mindepth 1 -delete
    tar -x${Z}f /restore.tar -C /pb/pb_data
    chown -R 10001 /pb/pb_data
  '
docker compose up -d pocketbase
for _ in $(seq 1 30); do
  if docker compose exec -T pocketbase wget -qO- http://127.0.0.1:8090/api/health >/dev/null 2>&1; then
    echo "Restored. Steady is running with the imported data."
    if [ "$KEEP_SESSIONS" = true ]; then
      echo "Sessions from the restored copy still work (--keep-sessions)."
    else
      ./accounts.sh rotate-sessions || echo "Couldn't sign everyone out: run sudo ./accounts.sh rotate-sessions" >&2
    fi
    exit 0
  fi
  sleep 2
done
echo "The server didn't come up. Check: docker compose logs pocketbase" >&2
exit 1
