#!/usr/bin/env bash
# Signs a Steady release, on OpenWorks' own computer (never on a server or in CI):
#   deploy/release.sh 1.0.0
#
# It tags the current main commit as v1.0.0 and the web app CI built from it (on the web-dist
# branch) as web-v1.0.0, both signed with your SSH key, and pushes the two tags. Servers with
# deploy/secrets/allowed_signers install only signed tags (see update.sh), so nothing reaches a
# practice until it has been signed here.
#
# One-time setup on this computer:
#   git config --global gpg.format ssh
#   git config --global user.signingkey ~/.ssh/id_ed25519.pub
# and on each server, the matching line in deploy/secrets/allowed_signers:
#   tiaan@tedvdm.com namespaces="git" ssh-ed25519 AAAA... (the contents of id_ed25519.pub)
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."

ver="${1:-}"
[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Usage: deploy/release.sh 1.2.3" >&2; exit 1; }
tag="v$ver"; web="web-$tag"

[ "$(git config gpg.format)" = ssh ] && [ -n "$(git config user.signingkey)" ] || {
  echo "Set up SSH signing first (see the top of this file)." >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "There are uncommitted changes here." >&2; exit 1; }
git fetch -q origin main web-dist --tags
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && { echo "$tag already exists." >&2; exit 1; }

sha="$(git rev-parse origin/main)"
built="$(git log -1 --format=%s origin/web-dist)"
[ "$built" = "Web app built from ${sha:0:7}" ] || {
  echo "The web app on web-dist was built from a different commit:" >&2
  echo "  web-dist: $built" >&2
  echo "  main:     ${sha:0:7}" >&2
  echo "Wait for the 'Test builds' run for main to finish (GitHub Actions), then try again." >&2
  exit 1; }

echo "Release $tag"
echo "  code:    ${sha:0:7}  $(git log -1 --format=%s "$sha")"
echo "  web app: $(git rev-parse --short origin/web-dist)  $built"
echo "  changes since the last release:"
last="$(git tag -l 'v[0-9]*' | sort -V | tail -1)"
git log --no-merges --format='    %h %s' "${last:+$last..}$sha" | head -30
read -r -p "Sign and publish $tag? Type yes: " ok
[ "$ok" = yes ] || exit 1

git tag -s "$tag" -m "Steady $ver" "$sha"
git tag -s "$web" -m "Steady $ver web app" origin/web-dist
# check both signatures the way a server will
signers="$(mktemp)"; trap 'rm -f "$signers"' EXIT
key="$(git config user.signingkey)"; key="${key/#\~/$HOME}"
printf '%s namespaces="git" %s\n' "$(git config user.email)" "$(cat "$key")" > "$signers"
git -c gpg.ssh.allowedSignersFile="$signers" verify-tag "$tag"
git -c gpg.ssh.allowedSignersFile="$signers" verify-tag "$web"
git push -q origin "$tag" "$web"
echo "Published. Servers offer $tag under Settings > Server and updates (and check every night)."
