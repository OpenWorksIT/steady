# Fleet view

One page for OpenWorks IT that shows every practice's Steady server: whether it's healthy, which
version it runs and whether a newer signed release is waiting, how full its disk is, how old its
newest backup is, and how many patients, staff and check-ins it has. Each server has three
buttons: **Check for updates**, **Update** and **Restart Steady**.

It never shows anything about patients: the servers send only versions, health, counts and
backup age. Sign-in takes a name, a password and a code from an authenticator app.

The code is in `fleet/` (Go, standard library only). It runs on OpenWorks' own server (vps1) at
**fleet.steadyapp.co.za**, never on a practice's server.

## How it works

- Every minute the fleet view asks each server for `GET /api/steady/fleet`, sending that
  server's `STEADY_MONITOR_KEY`. That key can only read.
- The buttons send `POST /api/steady/fleet/request` with the server's `STEADY_FLEET_KEY`. That
  key can only ask the server to check, update or restart; it can't read anything.
- The server leaves the request for `deploy/ctl/steady-ctl.sh`, which does the work as root.
  **Update** first saves a copy of the data, then installs the newest release signed by
  OpenWorks (servers with `secrets/allowed_signers`). **Restart** restarts Steady's containers,
  not the whole machine.
- Without the right key, both routes answer 404, as if they weren't there.
- Sign-ins (and failed ones) and every button press go to the fleet view's audit log.

## On each practice server

1. Make a fleet key (the monitor key is already there from `gen-keys.sh`):
   ```bash
   cd /opt/steady/deploy
   echo "STEADY_FLEET_KEY=$(openssl rand -base64 30 | tr '+/' '-_' | tr -d '=\n')" | sudo tee -a .env
   sudo docker compose up -d
   ```
2. In-app updates must be set up (`sudo ./ctl/install.sh`), or the buttons can't do anything.
3. Backups: the fleet view shows the newest file in `/srv/backups/steady` (set
   `STEADY_BACKUP_DIR` in `.env` if they go elsewhere).
4. Give OpenWorks the server's address, `STEADY_MONITOR_KEY` and `STEADY_FLEET_KEY`, through
   a password manager, not email.

The fleet route needs Steady 1.0.3 or newer.

## Setting up the fleet view (vps1)

1. DNS: an A record for `fleet.steadyapp.co.za` pointing at vps1.
2. The data folder, readable only by the fleet view:
   ```bash
   sudo install -d -m 700 -o 65532 -g 65532 /var/lib/steady-fleet
   ```
3. `/var/lib/steady-fleet/servers.json`, one entry per practice (`fleetKey` is optional; without
   it the fleet view only looks):
   ```json
   [
     {"name": "VR Clinical Psychology", "url": "https://vr.steadyapp.co.za",
      "monitorKey": "...", "fleetKey": "..."}
   ]
   ```
   Then `sudo chown 65532:65532 /var/lib/steady-fleet/servers.json && sudo chmod 600 /var/lib/steady-fleet/servers.json`.
   Changes are picked up within a minute; no restart needed.
4. Start it on the shared `edge` network, and add its site to the Caddy that owns ports 80/443:
   ```bash
   cd /opt/steady
   sudo docker compose -f fleet/compose.yml up -d --build
   sudo cp fleet/fleet.caddy /opt/shap/deploy/vps/sites/fleet.caddy
   cd /opt/shap/deploy/vps && sudo docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
   ```
5. Add yourself. It asks for a password (14 characters or more) and prints the key for your
   authenticator app:
   ```bash
   cd /opt/steady && sudo docker compose -f fleet/compose.yml run --rm fleet adduser tiaan
   ```

Other commands, the same way: `passwd <name>`, `resettotp <name>` (a lost phone),
`deluser <name>` (signs that person out at once).

## Updating the fleet view

```bash
cd /opt/steady && git pull && sudo docker compose -f fleet/compose.yml up -d --build
```

## Security notes

- The keys in `servers.json` let the fleet view read health and ask for updates or restarts on
  every practice server, so the file and the vps1 account that can read it matter. Keep SSH to
  vps1 key-only, as on the practice servers.
- Wrong sign-ins are limited per address and per name (a 15-minute pause); a code from the
  authenticator app works only once.
- Sessions end after 30 minutes idle or 8 hours, and when the fleet view restarts.
- A leaked fleet key lets someone restart a server or install a release OpenWorks has already
  signed, nothing more. Replace it in `.env` and `servers.json` if it ever leaks.
