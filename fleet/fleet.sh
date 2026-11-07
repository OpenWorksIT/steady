#!/bin/sh
# The fleet view's commands for devs, over SSH on vps1. Everything that changes a practice's
# server runs here (the website only looks), and the fleet view's log says who ran it.
#   sudo /opt/steady-ops/fleet/fleet.sh servers
#   sudo /opt/steady-ops/fleet/fleet.sh update vr
# See docs/FLEET.md, "Changing a server".
# SPDX-License-Identifier: AGPL-3.0-or-later
set -eu
cd "$(dirname "$0")/.."
exec docker compose -f fleet/compose.yml run --rm -e FLEET_ACTOR="${SUDO_USER:-$(id -un)}" fleet "$@"
