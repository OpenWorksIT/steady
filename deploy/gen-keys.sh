#!/usr/bin/env bash
# Creates the push relay secret and the monitor and fleet keys, and lets the push relay
# read its keys in secrets/: Apple's .p8 (iPhones) and Firebase's fcm.json (Android). Run it again after
# copying either key in.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")"
umask 077
mkdir -p secrets
# the keys printed below go into .env: root only
[ -f .env ] && chmod 600 .env

# The relay runs as the distroless "nonroot" user (uid 65532) and must be able to read its keys:
# it may enter the folder (umask 077 above made it root-only) and read its own key files, which
# nobody else may read, but the files only root uses (allowed_signers, backup.age.pub) stay root's.
if [ "$(id -u)" = "0" ]; then
  chown root:65532 secrets && chmod 750 secrets
  for f in secrets/*; do
    [ -f "$f" ] || continue
    case "$f" in */allowed_signers|*.pub) chown root:root "$f" ;; *) chown 65532:65532 "$f" && chmod 600 "$f" ;; esac
  done
else
  echo "Note: as root, run 'chown root:65532 deploy/secrets && chmod 750 deploy/secrets', and for"
  echo "the relay's keys (the .p8 and fcm.json) 'chown 65532:65532 <file> && chmod 600 <file>'."
fi
[ -f secrets/fcm.json ] || echo "No secrets/fcm.json yet: Android phones get no notifications (docs/DEPLOY.md, step 3a)."

SECRET=$(openssl rand -base64 36 | tr '+/' '-_' | tr -d '=\n')
MONITOR=$(openssl rand -base64 30 | tr '+/' '-_' | tr -d '=\n')
FLEET=$(openssl rand -base64 30 | tr '+/' '-_' | tr -d '=\n')

cat <<EOF

Add these to deploy/.env:

PUSHER_SECRET=$SECRET
STEADY_MONITOR_KEY=$MONITOR
STEADY_FLEET_KEY=$FLEET

(Only replace PUSHER_SECRET if this is a new install; the server and relay must match.
STEADY_MONITOR_KEY and STEADY_FLEET_KEY can be added to an existing install at any time: then
docker compose up -d. Give only STEADY_FLEET_KEY to OpenWorks IT's fleet view, see docs/FLEET.md.)

The community needs nothing here: OpenWorks IT switches it on from the fleet view
(fleet community <server> on, docs/COMMUNITY.md), which makes this practice's key.
EOF
