# Fleet view

One page for OpenWorks IT that shows every practice's Steady server: whether it's healthy, which
version it runs and whether a newer signed release is waiting, how full its disk is, how old its
newest backup is, and how many patients, staff and check-ins it has. Each server has three
buttons: **Check for updates**, **Update** and **Restart Steady**.

It also shows each server's **security and privacy checks**, live: the server runs
`deploy/audit-server.sh` every 6 hours and hands the results over with its status, so the
overview says "all clear", "N to look at" or "N to fix" per server, the server's page lists
each one, and **Checks** (in the bar at the top) lists every server's findings by severity:
what to fix first, then what to look at, with a bar per server. With them come the privacy numbers the server counts itself: patients on an older
consent statement, deletion requests past 25 days, staff without two-step sign-in. This is the
standing picture of what the November 2026 security review found and fixed.

A server whose check **isn't running** is a red flag: "check not running" in red on the
overview (with a count at the top), first under "To fix" on **Checks**, and on the server's
page with the reason and the command to run there. Every 5 minutes each server reports its
check's timer (Steady 1.1.1 on), so the flag says which it is:

| The fleet view says | What it means | On the server |
|---|---|---|
| the check isn't installed | `steady-audit.timer` isn't there (an update doesn't install it) | `cd /opt/steady/deploy && sudo ./ctl/install.sh` |
| the check's timer is switched off | it's installed but not enabled | the same |
| the last check failed (exit-code, exit 2, ...) | `audit-server.sh` stopped with an error | `sudo journalctl -u steady-audit -n 50 --no-pager` |
| the check ran but Steady can't read its results | `out/audit.json` doesn't reach PocketBase | `sudo ./ctl/install.sh` (it remounts the folder) |
| the check last ran ... and has stopped | no new results for 13 hours | `systemctl status steady-audit.timer steady-audit.service` |
| no check from this server | a server before 1.1.1 that sends no results | `sudo ./ctl/install.sh` |

A check that's running right now, or one that's installed and waiting for its first run, isn't
flagged.

**To do** (in the bar at the top) is OpenWorks' own list: what it has to do, look at or wait
for, across the practice servers, the community, the apps, the releases and the paperwork, and
the monthly upkeep round. See "To do" below.

It never shows anything about patients: the servers send only versions, health, counts, backup
age and what their checks found. Sign-in takes a name, a password and a code from an
authenticator app.

The code is in `fleet/` (Go, standard library only). It runs on OpenWorks' own server (vps1,
beside Shap and the test server) at **fleet.steadyapp.co.za**, from a signed release in its own
folder, never on a practice's server.

## How it works

- Every minute the fleet view asks each server for `GET /api/steady/fleet`, and the buttons send
  `POST /api/steady/fleet/request`, both with that server's `STEADY_FLEET_KEY`. That key opens
  those two routes and nothing else. (Not the monitor key: that one also reads feedback, which
  can hold screenshots.)
- The server leaves the request for `deploy/ctl/steady-ctl.sh`, which does the work as root.
  **Update** first saves a copy of the data, then installs the newest release signed by
  OpenWorks (servers with `secrets/allowed_signers`). **Restart** restarts Steady's containers,
  not the whole machine.
- Without the right key, both routes answer 404, as if they weren't there.
- After an update or restart, the server refuses another for 5 minutes (checks are fine).
- The fleet view never follows a redirect, so a server's key can't be sent somewhere else.
- Sign-ins (and failed ones) and every button press go to the fleet view's audit log.

## On each practice server

1. Make a fleet key (new installs already have one from `gen-keys.sh`):
   ```bash
   cd /opt/steady/deploy
   echo "STEADY_FLEET_KEY=$(openssl rand -base64 30 | tr '+/' '-_' | tr -d '=\n')" | sudo tee -a .env
   sudo docker compose up -d
   ```
2. In-app updates must be set up (`sudo ./ctl/install.sh`), or the buttons can't do anything.
   It also installs the security and privacy check (`steady-audit.timer`, every 6 hours, and
   once after each update), whose results the fleet view shows. An update doesn't install new
   services by itself: run `sudo ./ctl/install.sh` again after any update that adds one (1.1.0
   added the check), or the fleet view flags the server red.
3. Backups: the fleet view shows the newest file in `/srv/backups/steady` (set
   `STEADY_BACKUP_DIR` in `.env` if they go elsewhere).
4. Give OpenWorks the server's address and `STEADY_FLEET_KEY` (only that one) through a
   password manager, not email.

The fleet route needs Steady 1.0.3 or newer.

## Setting up the fleet view (vps1)

It holds every practice's fleet key, so it runs from a signed release in its own folder
(`/opt/steady-ops`), not from vps1's test checkout, which follows the test branch unsigned. It
gets a Docker network of its own (`fleet-edge`) that only it and Shap's Caddy are on.

1. **DNS:** an A record `fleet.steadyapp.co.za` pointing at vps1.
2. **The code, its signature checked.** Put OpenWorks' signing key in
   `/root/steady-allowed-signers` (the same line as a practice server's
   `deploy/secrets/allowed_signers`), then, with the newest release for `v1.0.5`:
   ```bash
   sudo git clone -q https://github.com/OpenWorksIT/steady.git /opt/steady-ops
   cd /opt/steady-ops
   sudo git -c gpg.format=ssh -c gpg.ssh.allowedSignersFile=/root/steady-allowed-signers verify-tag v1.0.5 \
     && sudo git checkout -q --detach v1.0.5
   ```
   It must say **Good "git" signature**.
3. **The network and Shap's Caddy.**
   ```bash
   sudo docker network create fleet-edge
   sudo tee /opt/shap/deploy/vps/fleet-edge.yml >/dev/null <<'EOF'
   # Shap's Caddy also on fleet-edge, where only it and Steady's fleet view are
   services:
     caddy:
       networks:
         fleet-edge: {}
   networks:
     fleet-edge:
       external: true
   EOF
   ```
   Add `:fleet-edge.yml` to the end of `COMPOSE_FILE` in `/opt/shap/deploy/vps/.env`, then:
   ```bash
   cd /opt/shap/deploy/vps && sudo docker compose up -d caddy
   sudo cp /opt/steady-ops/fleet/fleet.caddy sites/fleet.caddy
   sudo docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
   ```
   `fleet/compose.yml` sets `FLEET_TRUSTED_PROXY: caddy`, Caddy's name on that network: only its
   `X-Forwarded-For` is believed, so nobody else can pretend to be a new address on every try.
4. **The data folder**, readable only by the fleet view, and
   `/var/lib/steady-fleet/servers.json`, one entry per server (addresses must be `https://`; the
   key is `STEADY_FLEET_KEY` from that server's `.env`):
   ```bash
   sudo install -d -m 700 -o 65532 -g 65532 /var/lib/steady-fleet
   sudo nano /var/lib/steady-fleet/servers.json
   ```
   ```json
   [
     {"name": "VR Clinical Psychology", "url": "https://vr.steadyapp.co.za", "fleetKey": "..."},
     {"name": "Test server (vps1)", "url": "https://steady.openworks.co.za", "fleetKey": "..."}
   ]
   ```
   Then `sudo chown 65532:65532 /var/lib/steady-fleet/servers.json && sudo chmod 600 /var/lib/steady-fleet/servers.json`.
   Changes are picked up within a minute; no restart needed.
5. **Start it and add yourself** (a name of a-z, 0-9, `.`, `-` or `_`). It asks for a password
   (14 characters or more) and prints the key for your authenticator app:
   ```bash
   cd /opt/steady-ops && sudo docker compose -f fleet/compose.yml up -d --build
   sudo docker compose -f fleet/compose.yml run --rm fleet adduser <name>
   ```
6. Once the community forum is up (docs/COMMUNITY.md), its numbers can show on the overview too.
   `/var/lib/steady-fleet/community.json`, same owner and mode as servers.json:
   ```json
   {"url": "https://community.steadyapp.co.za", "statsKey": "<the openworks-stats key>"}
   ```
   The fleet view asks the forum every 10 minutes and keeps only the counts (members, active
   this week, topics, posts), never titles, names or text.

Other commands, the same way (in `/opt/steady-ops`): `passwd <name>`, `resettotp <name>` (a lost phone),
`deluser <name>` (signs that person out at once).

## To do

OpenWorks' list of everything it has to see to that isn't a server's own check (those are on
**Checks**). The lawyer and Kempie have docs of their own; what OpenWorks does about them goes
here.

- **List.** Each item has what needs to happen, where it belongs (OpenWorks, the community, a
  practice server by name, and so on), now, soon or later, and a status: *On the list*, *To look
  at* (a decision, or something to check), *Waiting* (on whom), *Done* or *Not doing*. A date
  and a link are optional. The list is grouped by now, soon and later; within each, what's past
  its date comes first. The buttons above it show one status or one area.
- **Done** needs no form: the button on the list closes it as you, now. From the item's own
  page, a note says what was done ("renewed until 2027"). Everything that happens to an item is
  in its history and in the audit log, with who did it.
- **Monthly upkeep** is the round in [UPKEEP.md](UPKEEP.md), one line per item, confirmed once
  a month with your name and the time. Earlier months stay as they were. What's left open goes
  on the list.
- Never anything about patients, in either.

It is kept in `todo.json` in the data folder (same owner and mode as the rest). The first start
fills it with the list as it stood in November 2026 (`fleet/web/todo-seed.json`); after that it
is only what people add and change. A copy of `/var/lib/steady-fleet` keeps it with the rest.

## Updating the fleet view

To a newer signed release only, its signature checked (here `v1.0.6`):

```bash
cd /opt/steady-ops && sudo git fetch -q --tags
sudo git -c gpg.format=ssh -c gpg.ssh.allowedSignersFile=/root/steady-allowed-signers verify-tag v1.0.6 \
  && sudo git checkout -q --detach v1.0.6 && sudo docker compose -f fleet/compose.yml up -d --build
```

## Security notes

- The keys in `servers.json` let the fleet view read health and ask for updates or restarts on
  every practice server, so the file and the vps1 accounts that can read it matter. Keep SSH to
  vps1 key-only, as on the practice servers.
- Sign-in tries are limited to 8 per address (IPv6: per /64) per 15 minutes. Wrong
  authenticator codes after a right password are limited to 10 per name, so someone without the
  password can't lock you out. A code works only once.
- A session lasts while its tab is open, for a screen that stays on: every page holds a hidden
  frame (`/alive`, no scripts) that asks once a minute, and that keeps it going. It ends when you
  sign out, when the browser closes (the cookie is for the browser session only), when the fleet
  view restarts, or 10 minutes after the tab closed or the computer went to sleep.
- Pages aren't compressed (the Caddy site has no `encode`), so the form tokens can't be guessed
  through compression.
- A leaked fleet key lets someone restart a server or install a release OpenWorks has already
  signed, nothing more. Replace it in `.env` and `servers.json` if it ever leaks.
