# Fleet view

One page for OpenWorks IT that shows every practice's Steady server: whether it's healthy, which
version it runs and whether a newer signed release is waiting, how full its disk is, how old its
newest backup is, and how many patients, staff and check-ins it has. Each server has three
buttons: **Check for updates**, **Update** and **Restart Steady**.

It also shows each server's **security and privacy checks**, live: the server runs
`deploy/audit-server.sh` every 6 hours and hands the results over with its status, so the
overview says "all clear", "N to look at" or "N to fix" per server, and the server's page lists
each one. With them come the privacy numbers the server counts itself: patients on an older
consent statement, deletion requests past 25 days, staff without two-step sign-in. This is the
standing picture of what the November 2026 security review found and fixed; a check that stops
running shows as such.

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
   once after each update), whose results the fleet view shows. Run it again after updating to
   Steady 1.0.6 to get the check.
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
- Sessions end after 30 minutes without a click (the pages' own refresh doesn't count), after
  8 hours, and when the fleet view restarts.
- Pages aren't compressed (the Caddy site has no `encode`), so the form tokens can't be guessed
  through compression.
- A leaked fleet key lets someone restart a server or install a release OpenWorks has already
  signed, nothing more. Replace it in `.env` and `servers.json` if it ever leaks.
