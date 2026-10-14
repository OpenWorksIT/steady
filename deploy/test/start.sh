#!/usr/bin/env bash
# Starts the Steady test stack on this PC and prints the address to use on phones.
#   ./start.sh            start (or restart) and show details
#   ./start.sh --update   also fetch the latest web app build from GitHub first
#   ./start.sh --stop     stop everything (data is kept)
#   ./start.sh --reset    stop and DELETE all test data
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")"
REPO="OpenWorksIT/steady"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Please install $1 first." >&2; exit 1; }; }
need docker
need curl
need openssl
need python3
docker compose version >/dev/null 2>&1 || { echo "Docker Compose v2 is needed (docker compose ...)." >&2; exit 1; }

compose() { docker compose --env-file .env -f compose.yml "$@"; }

case "${1:-}" in
  --stop) compose --profile named --profile quick down; exit 0 ;;
  --reset)
    read -r -p "Delete ALL test data (accounts, check-ins, results)? Type yes: " ok
    [ "$ok" = yes ] || exit 1
    compose --profile named --profile quick down -v; exit 0 ;;
esac

rand() { openssl rand -base64 "$1" | tr '+/' '-_' | tr -d '=\n'; }

# ---------- first run: keys and accounts ----------
umask 077
mkdir -p secrets web
chmod 755 secrets   # readable by the relay container
if [ ! -f secrets/vapid.pem ]; then
  openssl ecparam -name prime256v1 -genkey -noout -out secrets/vapid.pem
fi
chmod 644 secrets/vapid.pem   # the relay runs as a different user inside its container
if [ ! -f .env ]; then
  VAPID_PUB=$(openssl ec -in secrets/vapid.pem -pubout -outform DER 2>/dev/null | tail -c 65 | base64 | tr '+/' '-_' | tr -d '=\n')
  cat > .env <<EOF
# Steady test stack settings (created by start.sh). Keep this file private.
STEADY_PRACTICE_NAME=Steady test
PUSHER_SECRET=$(rand 36)
STEADY_VAPID_PUBLIC_KEY=$VAPID_PUB
VAPID_SUBJECT=mailto:test@example.com

# Named tunnel (recommended): paste the token from Cloudflare and set the address you gave it.
# Leave empty to use a quick tunnel with a random trycloudflare.com address.
TUNNEL_TOKEN=
PUBLIC_URL=

# Accounts created on first start
SUPERUSER_EMAIL=admin@steady.test
SUPERUSER_PASSWORD=$(rand 18)
CLINICIAN_EMAIL=clinician@steady.test
CLINICIAN_PASSWORD=$(rand 12)
CLINICIAN_NAME=Test Clinician
EOF
  echo "Created deploy/test/.env"
fi
umask 022
set -a; . ./.env; set +a

# ---------- web app ----------
if [ "${1:-}" = "--update" ] || [ ! -f web/index.html ]; then
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    echo "Fetching the latest web app build..."
    tmp=$(mktemp -d)
    gh release download test-build -R "$REPO" -p steady-web.zip -D "$tmp" --clobber
    rm -rf web && mkdir web
    (cd web && unzip -q "$tmp/steady-web.zip")
    rm -rf "$tmp"
  else
    echo "Note: no web app yet. Install the GitHub CLI and run 'gh auth login', then './start.sh --update',"
    echo "      or download steady-web.zip from https://github.com/$REPO/releases/tag/test-build and unzip it into deploy/test/web/"
  fi
fi

# ---------- start ----------
if [ "${NO_TUNNEL:-}" = 1 ]; then PROFILE=none        # local only (used by CI)
elif [ -n "${TUNNEL_TOKEN:-}" ]; then PROFILE=named
else PROFILE=quick; fi
compose --profile named --profile quick down --remove-orphans >/dev/null 2>&1 || true
compose --profile "$PROFILE" up -d --build

echo -n "Waiting for the server"
for _ in $(seq 1 60); do
  curl -fsS http://localhost:8090/api/health >/dev/null 2>&1 && break
  echo -n "."; sleep 2
done
echo
curl -fsS http://localhost:8090/api/health >/dev/null || { echo "The server didn't start. See: docker compose -f deploy/test/compose.yml logs pocketbase" >&2; exit 1; }

# ---------- accounts (idempotent) ----------
compose exec -T pocketbase /pb/pocketbase superuser upsert "$SUPERUSER_EMAIL" "$SUPERUSER_PASSWORD" --dir=/pb/pb_data >/dev/null

json() { python3 -c 'import json,sys; print(json.dumps(dict(zip(sys.argv[1::2], sys.argv[2::2]))))' "$@"; }
TOKEN=$(curl -fsS http://localhost:8090/api/collections/_superusers/auth-with-password \
  -H 'Content-Type: application/json' \
  -d "$(json identity "$SUPERUSER_EMAIL" password "$SUPERUSER_PASSWORD")" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')

EXISTS=$(curl -fsS -G http://localhost:8090/api/collections/users/records \
  -H "Authorization: $TOKEN" --data-urlencode "filter=email='$CLINICIAN_EMAIL'" | python3 -c 'import json,sys; print(json.load(sys.stdin)["totalItems"])')
if [ "$EXISTS" = "0" ]; then
  curl -fsS http://localhost:8090/api/collections/users/records -H "Authorization: $TOKEN" -H 'Content-Type: application/json' \
    -d "$(python3 -c 'import json,sys; print(json.dumps({"email":sys.argv[1],"password":sys.argv[2],"passwordConfirm":sys.argv[2],"name":sys.argv[3],"role":"clinician","active":True,"verified":True,"tzOffset":120}))' "$CLINICIAN_EMAIL" "$CLINICIAN_PASSWORD" "$CLINICIAN_NAME")" >/dev/null
  echo "Created clinician account"
fi

# ---------- address ----------
URL="${PUBLIC_URL:-}"
if [ "$PROFILE" = quick ]; then
  echo -n "Waiting for the quick tunnel"
  for _ in $(seq 1 30); do
    URL=$(compose logs quicktunnel 2>/dev/null | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' | tail -1 || true)
    [ -n "$URL" ] && break
    echo -n "."; sleep 2
  done
  echo
fi

cat <<EOF

Steady test server is running.

  Address for phones   ${URL:-(set PUBLIC_URL in deploy/test/.env to the hostname you gave the tunnel)}
  Web app              ${URL:-<address>}/      (iPhone: open in Safari, Share > Add to Home Screen)
  Dashboard (this PC)  http://localhost:8090/_/
      superuser        $SUPERUSER_EMAIL  /  $SUPERUSER_PASSWORD

  Clinician sign-in    $CLINICIAN_EMAIL  /  $CLINICIAN_PASSWORD
  Patients             sign in as the clinician, tap Invite, and join with the code on another phone

EOF
if [ "$PROFILE" = quick ]; then
  echo "  Quick tunnel: the address changes every start, and live updates inside the app won't work."
  echo "  Push notifications still do. Set up a named tunnel for Friday (see deploy/test/README.md)."
  echo
fi
