#!/usr/bin/env bash
# Creates the push relay secret and a VAPID key pair for UnifiedPush.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")"
umask 077
mkdir -p secrets

if [ ! -f secrets/vapid.pem ]; then
  openssl ecparam -name prime256v1 -genkey -noout -out secrets/vapid.pem
  echo "Created secrets/vapid.pem"
else
  echo "Keeping existing secrets/vapid.pem"
fi

# The relay runs as the distroless "nonroot" user (uid 65532) and must be able to read its keys.
if [ "$(id -u)" = "0" ]; then
  chown 65532:65532 secrets/* 2>/dev/null || true
else
  echo "Note: run 'sudo chown 65532:65532 deploy/secrets/*' so the push relay can read its keys."
fi

# Uncompressed P-256 public key (65 bytes), base64url without padding
PUB=$(openssl ec -in secrets/vapid.pem -pubout -outform DER 2>/dev/null | tail -c 65 | base64 | tr '+/' '-_' | tr -d '=\n')
SECRET=$(openssl rand -base64 36 | tr '+/' '-_' | tr -d '=\n')
MONITOR=$(openssl rand -base64 30 | tr '+/' '-_' | tr -d '=\n')

cat <<EOF

Add these to deploy/.env:

PUSHER_SECRET=$SECRET
STEADY_VAPID_PUBLIC_KEY=$PUB
STEADY_MONITOR_KEY=$MONITOR

(Only replace PUSHER_SECRET if this is a new install; the server and relay must match.
STEADY_MONITOR_KEY can be added to an existing install at any time: then docker compose up -d.)
EOF
