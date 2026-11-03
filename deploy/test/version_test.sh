#!/usr/bin/env bash
# Checks deploy/version.sh on a small made-up history (CI, the server job).
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
r="$(mktemp -d)"; trap 'rm -rf "$r"' EXIT
g() { git -C "$r" -c user.name=t -c user.email=t@example.org "$@"; }
v() { "$here/version.sh" "$1" "$r"; }
fail=0
expect() { [ "$(v "$1")" = "$2" ] && echo "ok   $1 -> $2" || { echo "FAIL $1 -> $(v "$1"), want $2"; fail=1; }; }
g init -q -b main
g commit -q --allow-empty -m beta1
g commit -q --allow-empty -m beta2
expect HEAD "0.9 test 2"                       # the beta, before any release or VERSION
echo 1.0.0 > "$r/VERSION"; g add VERSION; g commit -q -m "1.0.0"; g tag v1.0.0
expect HEAD "1.0.0"
g commit -q --allow-empty -m fix
expect HEAD "1.0.0 test 1"                     # after a release, before VERSION moves on
echo 1.1.0 > "$r/VERSION"; g add VERSION; g commit -q -m "towards 1.1.0"
g commit -q --allow-empty -m more
expect HEAD "1.1.0 test 3"
g tag v1.1.0
expect HEAD "1.1.0"
expect v1.0.0 "1.0.0"
expect HEAD~3 "1.0.0"
exit $fail
