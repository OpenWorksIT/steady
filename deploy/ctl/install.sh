#!/usr/bin/env bash
# One-time setup on the server: lets psychologists marked "serverAdmin" check for and install
# updates from the app (Settings > Server and updates), checks every night, and records disk,
# memory and load every 5 minutes for Settings > Server health, and runs the security and privacy
# check (audit-server.sh) every 6 hours for OpenWorks' fleet view.
# Run again after it changes (harmless).
#   sudo /opt/steady/deploy/ctl/install.sh
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")"
command -v jq >/dev/null || apt-get install -y jq
# deploy/.env holds the server's keys and passwords: root only
[ -f ../.env ] && chmod 600 ../.env
# PocketBase runs as uid 10001 in its container: it may leave a request in in/ and read out/
# (mounted read-only); root keeps its logs in work/. See the top of steady-ctl.sh.
install -d -m 0755 -o root -g root /var/lib/steady/ctl
chown root:root /var/lib/steady/ctl && chmod 0755 /var/lib/steady/ctl
install -d -m 0770 -o root -g 10001 /var/lib/steady/ctl/in
install -d -m 0755 -o root -g root /var/lib/steady/ctl/out /var/lib/steady/ctl/work
chmod 0700 /var/lib/steady/ctl/work
install -d -m 0700 /var/backups/steady
chmod +x steady-ctl.sh
install -m 0644 steady-ctl.path steady-ctl.service steady-check.service steady-check.timer steady-stats.service steady-stats.timer \
  steady-audit.service steady-audit.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now steady-ctl.path steady-check.timer steady-stats.timer steady-audit.timer
# Mount the folder into PocketBase (the compose file already names it) and take a first look.
cd .. && docker compose up -d
/opt/steady/deploy/ctl/steady-ctl.sh check || true
/opt/steady/deploy/ctl/steady-ctl.sh stats || true
# the first security and privacy check for the fleet view, in the background (a minute or two)
systemctl start --no-block steady-audit.service || true
echo "Done. Server admins now see Settings > Server and updates in the app."
