# Fleet view

One page for OpenWorks IT that shows every practice's Steady server: whether it's healthy, which
version it runs and whether a newer signed release is waiting, how full its disk is, how old its
newest backup is, and how many patients, staff and check-ins it has. Each server has three
buttons: **Check for updates**, **Update** and **Restart Steady**.

It never shows anything about patients: the servers send only versions, health, counts and
backup age. Sign-in takes a name, a password and a code from an authenticator app.

The code is in `fleet/` (Go, standard library only). It runs on OpenWorks' own server (vps3, [OPS-SERVER.md](OPS-SERVER.md)) at
**fleet.steadyapp.co.za**, never on a practice's server.

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
3. Backups: the fleet view shows the newest file in `/srv/backups/steady` (set
   `STEADY_BACKUP_DIR` in `.env` if they go elsewhere).
4. Give OpenWorks the server's address and `STEADY_FLEET_KEY` (only that one) through a
   password manager, not email.

The fleet route needs Steady 1.0.3 or newer.

## Setting up the fleet view (vps3)

1. DNS and the server itself: [OPS-SERVER.md](OPS-SERVER.md), steps 1 to 3.
2. The data folder, readable only by the fleet view:
   ```bash
   sudo install -d -m 700 -o 65532 -g 65532 /var/lib/steady-fleet
   ```
3. `/var/lib/steady-fleet/servers.json`, one entry per practice (addresses must be `https://`):
   ```json
   [
     {"name": "VR Clinical Psychology", "url": "https://vr.steadyapp.co.za", "fleetKey": "..."}
   ]
   ```
   Then `sudo chown 65532:65532 /var/lib/steady-fleet/servers.json && sudo chmod 600 /var/lib/steady-fleet/servers.json`.
   Changes are picked up within a minute; no restart needed.
4. Start it. It joins the `edge` network that `ops/compose.yml` made, and that Caddy
   already has its site (`fleet/fleet.caddy`). `compose.yml` sets
   `FLEET_TRUSTED_PROXY: caddy`, Caddy's name on that network: only its `X-Forwarded-For` is
   believed, so nobody else can pretend to be a new address on every try.
   ```bash
   cd /opt/steady && sudo docker compose -f fleet/compose.yml up -d --build
   ```
5. Once the community forum is up (docs/COMMUNITY.md), its numbers can show on the overview too.
   `/var/lib/steady-fleet/community.json`, same owner and mode as servers.json:
   ```json
   {"url": "https://community.steadyapp.co.za", "statsKey": "<the openworks-stats key>"}
   ```
   The fleet view asks the forum every 10 minutes and keeps only the counts (members, active
   this week, topics, posts), never titles, names or text.
6. Add yourself (a name of a-z, 0-9, `.`, `-` or `_`). It asks for a password (14 characters
   or more) and prints the key for your authenticator app:
   ```bash
   cd /opt/steady && sudo docker compose -f fleet/compose.yml run --rm fleet adduser <name>
   ```

Other commands, the same way: `passwd <name>`, `resettotp <name>` (a lost phone),
`deluser <name>` (signs that person out at once).

## Updating the fleet view

```bash
cd /opt/steady && sudo git pull && sudo docker compose -f fleet/compose.yml up -d --build
```

## Security notes

- The keys in `servers.json` let the fleet view read health and ask for updates or restarts on
  every practice server, so the file and the vps3 account that can read it matter. Keep SSH to
  vps3 key-only, as on the practice servers (OPS-SERVER.md, step 2).
- Sign-in tries are limited to 8 per address (IPv6: per /64) per 15 minutes. Wrong
  authenticator codes after a right password are limited to 10 per name, so someone without the
  password can't lock you out. A code works only once.
- Sessions end after 30 minutes without a click (the pages' own refresh doesn't count), after
  8 hours, and when the fleet view restarts.
- Pages aren't compressed (the Caddy site has no `encode`), so the form tokens can't be guessed
  through compression.
- A leaked fleet key lets someone restart a server or install a release OpenWorks has already
  signed, nothing more. Replace it in `.env` and `servers.json` if it ever leaks.
