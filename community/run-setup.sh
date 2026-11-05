#!/usr/bin/env bash
# Runs setup.py against the forum on this server, in one go, as root:
#   1. a one-off API key made inside the forum's container (this starts the forum's app once,
#      which takes a minute or two and prints nothing meanwhile), with Discourse's install page
#      switched off while it's at it
#   2. setup.py with that key (2 to 4 minutes the first time: the forum takes 60 admin requests a
#      minute, so it pauses now and then)
#   3. the key removed again through the forum's API, whatever happened in step 2
# Arguments go to setup.py, e.g. --dry-run, or --practice vr="VR Clinical Psychology".
#   sudo community/run-setup.sh
# See docs/COMMUNITY.md, step 4.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
url="${DISCOURSE_URL:-https://community.steadyapp.co.za}"
container="${DISCOURSE_CONTAINER:-community}"

docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null | grep -qx true \
  || { echo "The forum's container ($container) isn't running: cd /var/discourse && ./launcher start community" >&2; exit 1; }

echo "Making a one-off key inside the forum (starts the forum's app once: a minute or two, quietly)..."
key="$(timeout 900 docker exec "$container" rails runner \
  'SiteSetting.has_login_hint = false; SiteSetting.global_notice = ""; puts ApiKey.create!(description: "setup.py").key' \
  | tail -n 1)" || true
if ! [[ "$key" =~ ^[0-9a-f]{32,}$ ]]; then
  echo "No key came back from the forum. Try again; if it keeps failing, check memory (free -h)." >&2
  exit 1
fi
echo "Key made. Running setup.py..."
echo
DISCOURSE_URL="$url" DISCOURSE_API_USERNAME=system DISCOURSE_API_KEY="$key" \
  exec python3 -u community/setup.py --revoke-key "$@"
