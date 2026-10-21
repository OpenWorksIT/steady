# Deploying the Steady server

One small Linux server is enough for a practice: 1 vCPU, 1 GB RAM, 20 GB disk. Host it in South Africa (see PRIVACY.md).

## 1. Before you start

- A domain name pointing at the server, e.g. `steady.yourpractice.co.za`
- Docker with the Compose plugin
- An Apple Developer account (for iOS notifications)
- `openssl` and, for backups, [`age`](https://age-encryption.org)

## 2. Configure

```bash
git clone https://github.com/openworksIT/steady.git /opt/steady
cd /opt/steady/deploy
cp .env.example .env
sudo ./gen-keys.sh        # creates secrets/vapid.pem and prints PUSHER_SECRET and STEADY_VAPID_PUBLIC_KEY
```

Edit `.env`:

| Setting | What to put |
|---|---|
| `STEADY_DOMAIN`, `ACME_EMAIL` | Your domain and an email for Let's Encrypt |
| `STEADY_PRACTICE_NAME` | Shown on the sign-in screen and consent text |
| `PUSHER_SECRET`, `STEADY_VAPID_PUBLIC_KEY` | From `gen-keys.sh` |
| `VAPID_SUBJECT` | `mailto:` your IT contact |
| `APNS_*` | See step 3 |

Edit the consent statement in `server/pb_hooks/content/consent.md` with the practice, then bump `STEADY_CONSENT_VERSION`. The file is mounted read-only into the container, so a restart picks up changes.

## 3. Apple push (iOS)

1. developer.apple.com > Certificates, Identifiers & Profiles > **Keys** > create a key with **Apple Push Notifications service** enabled. Download the `.p8` (you can only download it once).
2. Copy it to `deploy/secrets/` and `sudo chown 65532:65532 deploy/secrets/*.p8`.
3. In `.env`: `APNS_KEY_FILE=/secrets/AuthKey_XXXX.p8`, `APNS_KEY_ID` (shown with the key), `APNS_TEAM_ID` (top right of the developer portal), `APNS_TOPIC` = the app's bundle identifier.

## 4. Start

```bash
docker compose up -d --build
docker compose logs -f pocketbase pusher
```

The PocketBase image downloads the pinned release from GitHub and checks it against the published checksums.

## 5. First-time setup in the dashboard

The dashboard is at `https://<domain>/_/`. The Caddyfile only allows it from private addresses: edit the ranges, or use an SSH tunnel (`ssh -L 8090:localhost:8090` and expose port 8090 on 127.0.0.1 temporarily).

1. Create the superuser account (PocketBase prints a one-time setup link in the logs on first start).
2. **Settings > Mail settings**: configure SMTP so password resets work.
3. **Collections > _superusers > Options**: turn on **Multi-factor authentication** (needs SMTP from step 2), so the dashboard needs a password and an emailed code.
4. **Collections > users**: create each psychologist with `role = clinician`, `active` ticked, a name and email. Ask them to reset their password from the app. Passwords need at least 10 characters.
5. Don't turn on multi-factor authentication for **users** yet: the app doesn't ask for the emailed code, so psychologists couldn't sign in.

Rate limits and the trusted proxy header are set by a migration (`1760600000_steady_hardening.js`); adjust them under **Settings > Rate limits** if needed.

Patients never get accounts from the dashboard; psychologists create invite codes in the app.

## 6. Server hardening

Do these on the VPS before real patient data arrives:

- [ ] SSH with keys only (`PasswordAuthentication no`, `PermitRootLogin no`).
- [ ] Firewall: only 22 (ideally limited to your address or a VPN), 80 and 443 open.
- [ ] Automatic security updates (`unattended-upgrades` on Debian/Ubuntu).
- [ ] Docker's data on an encrypted volume (LUKS), or full-disk encryption if the provider supports it.
- [ ] `chmod 600 deploy/.env` and keep `deploy/secrets/` readable only by root and the relay (uid 65532).
- [ ] Edit the allowed ranges in the Caddyfile so the dashboard and superuser sign-in are reachable only from your office or VPN.
- [ ] Superuser multi-factor authentication on (step 5).
- [ ] Backups running and copied off the server (step 7), restore tested.
- [ ] Uptime monitoring on `https://<domain>/api/health`.
- [ ] Review and merge Dependabot pull requests (they run the full test suite first).

## 7. Backups

```bash
age-keygen -o backup-key.txt           # do this on a different machine; keep it safe
# copy the "public key" line into deploy/secrets/backup.age.pub on the server
sudo crontab -e
15 1 * * *  /opt/steady/deploy/backup.sh /srv/backups/steady
```

Backups are encrypted before they're written. Copy them off the server (another SA location). Test a restore at least once:

```bash
age -d -i backup-key.txt steady-<stamp>.tar.age | tar -x -C /tmp/restore
```

## 8. Updating

```bash
cd /opt/steady && git pull
cd deploy && docker compose up -d --build
```

Migrations run automatically on start. Take a backup first.

## Sharing a server (e.g. vps1 with Shap)

When another app's Caddy already owns ports 80 and 443, Steady runs without its own Caddy and
that Caddy forwards Steady's domain to it over a shared Docker network called `edge`.

**1. Read-only deploy key** (the repository is private). On the server:

```bash
sudo ssh-keygen -t ed25519 -N "" -C "vps1 steady (read-only)" -f /root/.ssh/steady_deploy
sudo cat /root/.ssh/steady_deploy.pub
```

On GitHub: the steady repository > **Settings > Deploy keys > Add deploy key**, paste it, leave
**Allow write access** off. Then:

```bash
sudo tee -a /root/.ssh/config <<'CFG'
Host github-steady
  HostName github.com
  User git
  IdentityFile /root/.ssh/steady_deploy
  IdentitiesOnly yes
CFG
sudo git clone git@github-steady:OpenWorksIT/steady.git /opt/steady
```

**2. DNS.** An A record for Steady's domain (e.g. `steady.openworks.co.za`) pointing at the server.

**3. Shared network and the other Caddy.** Once per server: `sudo docker network create edge`, and
put that Caddy on it (Shap: add `edge.yml` to `COMPOSE_FILE` in `/opt/shap/deploy/vps/.env`, then
`sudo docker compose up -d caddy`). Give it Steady's site:

```bash
sed 's/STEADY_DOMAIN/steady.openworks.co.za/' /opt/steady/deploy/proxy/steady.caddy \
  | sudo tee /opt/shap/deploy/vps/sites/steady.caddy
cd /opt/shap/deploy/vps && sudo docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

**4. Configure and start Steady.**

```bash
cd /opt/steady/deploy
sudo cp .env.example .env && sudo chmod 600 .env
sudo ./gen-keys.sh            # paste PUSHER_SECRET and STEADY_VAPID_PUBLIC_KEY into .env
sudo nano .env                # STEADY_DOMAIN, practice name, VAPID_SUBJECT, and uncomment
                              # COMPOSE_FILE=docker-compose.yml:behind-proxy.yml
sudo ./update.sh              # pulls, fetches the web app, builds and starts
```

**5. Accounts.** The dashboard is only reachable through an SSH tunnel:
`ssh -L 8091:localhost:8091 <you>@<server>`, then open `http://localhost:8091/_/`. Create the
superuser with `sudo docker compose exec pocketbase /pb/pocketbase superuser upsert <email> <password> --dir=/pb/pb_data`,
then psychologists as in step 5 above.

**Updating** is `sudo ./update.sh` in `/opt/steady/deploy`, or from the app (below).

**6. Updates from the app (optional).** Lets psychologists you trust check for and install
updates from Settings > Server and updates, the way Shap does; the server also checks every night.

```bash
sudo /opt/steady/deploy/ctl/install.sh
```

Then, in the dashboard, open **users**, edit the psychologist and tick **serverAdmin**. The app
only leaves a request; `deploy/ctl/steady-ctl.sh` does the work as root (outside the app), saves a
copy of the data to `/var/backups/steady/` first (the last 5 are kept, root only) and then runs
`update.sh`.

## Troubleshooting

| Symptom | Check |
|---|---|
| No notifications on iPhone | `docker compose logs pusher` for `apns 403` (wrong key/team) or `400 DeviceTokenNotForTopic` (`APNS_TOPIC` must equal the bundle id). Debug builds from Xcode use the APNs sandbox automatically. |
| No notifications on Android | The phone needs a UnifiedPush distributor app (e.g. ntfy) installed and chosen in Steady's settings. |
| "Can't reach the server" in the app | The app was built with the wrong `STEADY_SERVER`, or DNS/TLS isn't ready. |
| Psychologist can't sign in | `active` must be ticked and `role` set to clinician. |
