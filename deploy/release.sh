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
# sign what was looked over here: this computer must have exactly that commit checked out
[ "$(git rev-parse HEAD)" = "$sha" ] || {
  echo "This checkout ($(git rev-parse --short HEAD)) isn't GitHub's main (${sha:0:7}): git checkout main && git pull, look it over, then try again." >&2
  exit 1; }
built="$(git log -1 --format=%s origin/web-dist)"
[ "$built" = "Web app built from ${sha:0:7}" ] || {
  echo "The web app on web-dist was built from a different commit:" >&2
  echo "  web-dist: $built" >&2
  echo "  main:     ${sha:0:7}" >&2
  echo "Wait for the 'Test builds' run for main to finish (GitHub Actions), then try again." >&2
  exit 1; }

websha="$(git rev-parse origin/web-dist)"
# Who put that build there: it must be CI's own push (github-actions[bot]), after a successful
# "Test builds" run for this very commit on main. A push made with a stolen token or by a
# person shows up under their name instead. (The web app can't be read like the code can.)
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  repo="$(git remote get-url origin | sed -E 's#^.*github\.com[:/]([^/]+/[^/]+)$#\1#; s#\.git$##')"
  pushed="$(gh api "repos/$repo/activity?ref=refs/heads/web-dist&per_page=1" --jq '.[0] | "\(.actor.login) \(.after)"' 2>/dev/null || true)"
  runs="$(gh api "repos/$repo/actions/workflows/test-builds.yml/runs?head_sha=$sha&branch=main&status=success" --jq .total_count 2>/dev/null || echo 0)"
  if [ "$pushed" != "github-actions[bot] $websha" ] || [ "${runs:-0}" -lt 1 ]; then
    echo "The web app on web-dist doesn't look like CI's build of ${sha:0:7}:" >&2
    echo "  last push to web-dist: ${pushed:-unknown}" >&2
    echo "  successful 'Test builds' runs for this commit on main: ${runs:-0}" >&2
    echo "Don't sign it. Find out who pushed web-dist (the repository's Activity page on GitHub)." >&2
    exit 1
  fi
  webcheck="pushed by CI after a successful 'Test builds' run for this commit"
elif [ "${STEADY_SKIP_WEB_CHECK:-}" = yes ]; then
  webcheck="NOT checked who pushed it (STEADY_SKIP_WEB_CHECK=yes)"
else
  echo "Can't check who pushed the web app to web-dist: the GitHub CLI (gh) isn't installed or signed in." >&2
  echo "Install it and run gh auth login, then try again. (STEADY_SKIP_WEB_CHECK=yes signs without the check.)" >&2
  exit 1
fi
echo "Release $tag"
echo "  code:    ${sha:0:7}  $(git log -1 --format=%s "$sha")"
echo "  web app: ${websha:0:7}  $built"
echo "           $webcheck"
echo "           (the web app is CI's build; its commit $websha is written into the signed $tag,"
echo "            and servers install only that build with it)"
echo "  changes since the last release:"
last="$(git tag -l 'v[0-9]*' | sort -V | tail -1)"
# -n, not | head: head closing the pipe early would end this script here (pipefail)
git log --no-merges -n 30 --format='    %h %s' "${last:+$last..}$sha"
read -r -p "Sign and publish $tag? Type yes: " ok
[ "$ok" = yes ] || exit 1

git tag -s "$tag" -m "Steady $ver" -m "web-dist: $websha" "$sha"
git tag -s "$web" -m "Steady $ver web app" "$websha"
# check both signatures the way a server will
signers="$(mktemp)"; trap 'rm -f "$signers"' EXIT
key="$(git config user.signingkey)"; key="${key/#\~/$HOME}"
printf '%s namespaces="git" %s\n' "$(git config user.email)" "$(cat "$key")" > "$signers"
git -c gpg.ssh.allowedSignersFile="$signers" verify-tag "$tag"
git -c gpg.ssh.allowedSignersFile="$signers" verify-tag "$web"
git push -q origin "$tag" "$web"
echo "Published. Servers offer $tag under Settings > Server and updates (and check every night)."
# a copy of the release on this computer (see backup-repo.sh); a failure here changes nothing above
deploy/backup-repo.sh || echo "  (The local backup didn't run; try deploy/backup-repo.sh by hand.)" >&2
