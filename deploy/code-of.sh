#!/bin/sh
# Prints the code of one of OpenWorks' own services (the fleet view, the community sign-in
# bridge) as 12 hex characters: a fingerprint of its go.mod, Go files and web/ folder. Run in
# both Docker builds, so the fleet view knows the bridge's code for its own release and can tell
# when the bridge was built from something else (another checkout, or not rebuilt after an
# update). POSIX sh and busybox only.
#   deploy/code-of.sh <folder>
# SPDX-License-Identifier: AGPL-3.0-or-later
set -eu
cd "$1"
find . -type f \( -name go.mod -o -name '*.go' -o -path './web/*' \) | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -c1-12
