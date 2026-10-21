#!/usr/bin/env bash
# Brings this server up to date: latest code, latest web app, rebuilt containers.
#   ./update.sh
# The web app comes from the web-dist branch, which CI publishes; the same read-only
# deploy key that cloned the repo fetches it.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { echo "Create deploy/.env first (cp .env.example .env), then run gen-keys.sh." >&2; exit 1; }

echo "Pulling the latest code..."
git -C .. pull --ff-only

echo "Fetching the web app..."
if git -C .. fetch -q origin web-dist 2>/dev/null; then
  rm -rf web.new && mkdir web.new
  git -C .. archive origin/web-dist | tar -x -C web.new
  chmod -R a+rX web.new
  # refresh the contents in place: the running server has this folder mounted, and a
  # replaced folder would stay invisible to it until it restarts
  mkdir -p web
  find web -mindepth 1 -delete
  cp -a web.new/. web/
  rm -rf web.new
else
  echo "  No web-dist branch yet; keeping the current web app." >&2
  mkdir -p web
fi
chmod 755 web

echo "Building and starting..."
docker compose up -d --build

for _ in $(seq 1 30); do
  if docker compose exec -T pocketbase wget -qO- http://127.0.0.1:8090/api/health >/dev/null 2>&1; then
    echo "Steady is running."
    exit 0
  fi
  sleep 2
done
echo "The server didn't come up. Check: docker compose logs pocketbase" >&2
exit 1
