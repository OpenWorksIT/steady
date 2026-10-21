#!/usr/bin/env bash
# One-time setup on the server: lets psychologists marked "serverAdmin" check for and install
# updates from the app (Settings > Server and updates), and checks every night.
# Run again after it changes (harmless).
#   sudo /opt/steady/deploy/ctl/install.sh
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")"
command -v jq >/dev/null || apt-get install -y jq
# PocketBase runs as uid 10001 in its container: it may leave a request and read the status.
install -d -m 0770 -o root -g 10001 /var/lib/steady/ctl
install -d -m 0700 /var/backups/steady
chmod +x steady-ctl.sh
install -m 0644 steady-ctl.path steady-ctl.service steady-check.service steady-check.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now steady-ctl.path steady-check.timer
# Mount the folder into PocketBase (the compose file already names it) and take a first look.
cd .. && docker compose up -d
/opt/steady/deploy/ctl/steady-ctl.sh check || true
echo "Done. Server admins now see Settings > Server and updates in the app."
