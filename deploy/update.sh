#!/usr/bin/env bash
# Brings this server up to date: code, web app (with the Android app), rebuilt containers.
#   ./update.sh
#
# Signed releases (recommended, and required on live servers): when deploy/secrets/allowed_signers
# exists, this installs only release tags (v1.0.0, ...) signed by a key listed there, and the web
# app only from the matching signed web-v1.0.0 tag. A push to GitHub, a stolen token or a
# compromised CI run can then not reach a practice's server. OpenWorks signs releases with
# deploy/release.sh. Without the file it follows the main and web-dist branches, as test
# servers do.
#
# The web app's files are checked before use: no links, nothing outside its folder.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail

# All in a function: bash reads it whole before running it, so updating this very file below
# can't change what runs halfway through.
main() {
  cd "$(dirname "$0")"
  local repo=.. signers="$PWD/secrets/allowed_signers" code web
  [ -f .env ] || { echo "Create deploy/.env first (cp .env.example .env), then run gen-keys.sh." >&2; exit 1; }

  if [ -s "$signers" ]; then
    echo "Fetching signed releases..."
    git -C "$repo" fetch -q --tags --force origin
    code="$(latest_signed v "$signers")" || { echo "No signed release found (tags v1.2.3 signed by a key in secrets/allowed_signers). Nothing changed." >&2; exit 1; }
    web="web-$code"
    # everything is checked before anything changes
    if git -C "$repo" rev-parse -q --verify "refs/tags/$web" >/dev/null; then
      verify "$web" "$signers" || { echo "The web app tag $web isn't signed by a trusted key. Nothing changed." >&2; exit 1; }
      unpack_web "refs/tags/$web"
    else
      echo "  No signed web app for $code ($web); keeping the current one." >&2
    fi
    echo "  installing $code (signature checked)"
    git -C "$repo" checkout -q --detach "refs/tags/$code"
    [ -d web.new ] && swap_web
  else
    echo "Pulling the latest code (unsigned: test servers only; see the top of this file)..."
    git -C "$repo" checkout -q main 2>/dev/null || true
    git -C "$repo" pull -q --ff-only
    if git -C "$repo" fetch -q origin web-dist 2>/dev/null; then
      unpack_web origin/web-dist
      swap_web
    else
      echo "  No web-dist branch yet; keeping the current web app." >&2
    fi
  fi
  mkdir -p web && chmod 755 web
  # the practice's branding lives here and is never touched by updates (./brand.sh)
  mkdir -p brand && chmod 755 brand
  # the server-update folders (see ctl/steady-ctl.sh): the container may write only in/
  if [ -d /var/lib/steady/ctl ]; then
    chown root:root /var/lib/steady/ctl && chmod 0755 /var/lib/steady/ctl
    install -d -m 0770 -o root -g 10001 /var/lib/steady/ctl/in
    install -d -m 0755 -o root -g root /var/lib/steady/ctl/out
    install -d -m 0700 -o root -g root /var/lib/steady/ctl/work
  fi

  echo "Building and starting..."
  docker compose up -d --build

  # each build leaves the previous images behind; without this they slowly fill the disk
  docker image prune -f >/dev/null 2>&1 || true

  for _ in $(seq 1 30); do
    if docker compose exec -T pocketbase wget -qO- http://127.0.0.1:8090/api/health >/dev/null 2>&1; then
      echo "Steady is running."
      exit 0
    fi
    sleep 2
  done
  echo "The server didn't come up. Check: docker compose logs pocketbase" >&2
  exit 1
}

# git verify-tag against the allowed signers (SSH signatures).
verify() {
  git -C .. -c gpg.format=ssh -c gpg.ssh.program=ssh-keygen -c gpg.ssh.allowedSignersFile="$2" verify-tag "$1" >/dev/null 2>&1
}

# The newest tag like v1.2.3 whose signature checks out.
latest_signed() {
  local t
  for t in $(git -C .. tag -l "$1[0-9]*" | grep -E "^$1[0-9]+\.[0-9]+\.[0-9]+$" | sort -rV); do
    if verify "$t" "$2"; then echo "$t"; return 0; fi
    echo "  skipping $t: not signed by a trusted key" >&2
  done
  return 1
}

# Unpacks a web build into web.new/, refusing links and anything that isn't a plain file or folder.
unpack_web() {
  echo "Checking the web app ($1)..."
  rm -rf web.new && mkdir web.new
  git -C .. archive "$1" | tar -x --no-same-owner --no-same-permissions -C web.new
  if [ -n "$(find web.new ! -type f ! -type d -print -quit)" ]; then
    rm -rf web.new
    echo "The web app holds links or special files: refused. Nothing changed." >&2
    exit 1
  fi
  chmod -R a+rX,go-w web.new
}

# Puts web.new/ in place of web/.
swap_web() {
  echo "Installing the web app..."
  # refresh the contents in place: the running server has this folder mounted, and a
  # replaced folder would stay invisible to it until it restarts
  mkdir -p web
  find web -mindepth 1 -delete
  cp -a web.new/. web/
  rm -rf web.new
}

main "$@"
