#!/usr/bin/env bash
# Replaces ALL of this server's Steady data with a file from export-data.sh (or backup.sh,
# after decrypting it with age). Accounts, sessions and settings come with it, so people
# sign in with the same email and password as before.
#   sudo ./restore-data.sh /tmp/steady-data-20261019-0930.tar.gz
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")"
FILE="${1:?usage: restore-data.sh <steady-data file>}"
[ -f "$FILE" ] || { echo "No such file: $FILE" >&2; exit 1; }
FILE="$(realpath "$FILE")"
# read the whole listing (grep -q would stop early and, with pipefail, fail the check on big files)
LIST="$(tar -tzf "$FILE")" || { echo "$FILE can't be read as a .tar.gz (incomplete copy?)." >&2; exit 1; }
grep -q 'data.db$' <<<"$LIST" || { echo "$FILE doesn't look like Steady data (no data.db)." >&2; exit 1; }

read -r -p "This replaces ALL Steady data on this server with $(basename "$FILE"). Type yes to continue: " ok
[ "$ok" = yes ] || { echo "Nothing changed."; exit 1; }

docker compose stop pocketbase
docker compose run --rm --no-deps -u 0 --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
  -v "$FILE:/restore.tar.gz:ro" --entrypoint sh pocketbase -c '
    set -e
    find /pb/pb_data -mindepth 1 -delete
    tar -xzf /restore.tar.gz -C /pb/pb_data
    chown -R 10001 /pb/pb_data
  '
docker compose up -d pocketbase
for _ in $(seq 1 30); do
  if docker compose exec -T pocketbase wget -qO- http://127.0.0.1:8090/api/health >/dev/null 2>&1; then
    echo "Restored. Steady is running with the imported data."
    exit 0
  fi
  sleep 2
done
echo "The server didn't come up. Check: docker compose logs pocketbase" >&2
exit 1
