#!/usr/bin/env bash
# Prints Steady's version for a commit, the way people read it:
#   1.0.5           a release: the commit carries the v1.0.5 tag
#   1.1.0 test 23   on the way to 1.1.0 (VERSION, at the top of the repository): 23 changes after
#                   the last release
#   deploy/version.sh [COMMIT] [REPO]    (default: HEAD of this repository)
#
# Large updates add .1 (1.1.0), small ones .0.1 (1.0.6); 1.0.0 is the version vps2 started on,
# and the betas before it count as 0.9 and earlier. docs/VERSIONS.md lists them.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
commit="${1:-HEAD}"
repo="${2:-$(cd "$(dirname "$0")/.." && pwd)}"
g() { git -C "$repo" "$@"; }
c="$(g rev-parse -q --verify "$commit^{commit}")" || { echo "?"; exit 0; }
# a release: the newest version tag on this very commit
t="$(g tag --points-at "$c" -l 'v[0-9]*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -rV | head -1 || true)"
if [ -n "$t" ]; then echo "${t#v}"; exit 0; fi
# work in between: the version it's heading for, and how far from the last release
last="$(g describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' "$c" 2>/dev/null || true)"
base="$(g show "$c:VERSION" 2>/dev/null | tr -d ' \r\n' || true)"
[[ "$base" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || base="${last#v}"
n="$(g rev-list --count "${last:+$last..}$c" 2>/dev/null || echo 0)"
echo "${base:-0.9} test $n"
