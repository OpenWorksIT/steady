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
| `STEADY_PRACTICE_NAME` | Only for servers without an installed brand (below); the practice's name now comes from `./brand.sh` |
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

## 4a. Practice branding

The practice's name, tagline, accent colour and logo are installed by OpenWorks IT, outside
the code, so updates never touch them ([BRAND.md](BRAND.md)):

```sh
deploy/brand.sh push <server> <brand folder>   # from your own computer
sudo ./brand.sh install <brand folder>          # or on the server
```

## 4b. Watching the server

```sh
./health.sh              # speed, errors, database, disk and memory, in a few lines
watch -n 30 ./health.sh  # keep it on screen
./health.sh --json       # everything, for a dashboard
```

It needs `STEADY_MONITOR_KEY` in `.env` (`./gen-keys.sh` prints one; then `docker compose up -d`).
Disk, memory and load come from `deploy/ctl` (run `sudo ./ctl/install.sh` again after updating, to
add the 5-minute stats timer). Limits and when to move up a server size: [CAPACITY.md](CAPACITY.md).

## 5. Accounts

PocketBase's own dashboard (`/_/`) is **closed**: it showed every record to anyone holding a
superuser login, which is the kind of open tap that gets forgotten. Superuser sign-in is refused
from anywhere but inside the server container. Accounts are managed in two places:

**On the server, by OpenWorks** (`deploy/accounts.sh`, run with sudo in `/opt/steady/deploy`):

```bash
sudo ./accounts.sh add-clinician "Kempie van Rooyen" kempie@vrpsych.co.za --master   # the master clinician
sudo ./accounts.sh add-admin "Front desk" reception@vrpsych.co.za                     # practice administrator
sudo ./accounts.sh add-admin "OpenWorks support" support@openworks.co.za --server-admin
sudo ./accounts.sh list                         # who has which role, and who still lacks two-step sign-in
sudo ./accounts.sh reset <email> [--two-step]   # a temporary password (and a fresh two-step set-up)
sudo ./accounts.sh set <email> master|server-admin|active on|off
sudo ./accounts.sh audit --patient <id>         # who looked at a patient's data (POPIA access requests)
sudo ./accounts.sh check                        # proxy header, rate limits, dashboard closed
sudo ./accounts.sh demo-patients <email> [--remove]   # three fictional patients for the RADR tab
```

Each run makes a superuser that exists only for that command, signs in from inside the
container, and deletes it again. New accounts and resets print a **temporary password**: give it
by phone or in person. The person must choose their own password before they can do anything,
then set up two-step sign-in.

**In the app**, by the people at the practice:

| Who | Can | Can't |
|---|---|---|
| Psychologist | Invite patients, see and send to their own patients, reset their own patients' passwords, share a patient (read only) with a colleague, export their own patients' records | See other psychologists' patients unless shared with them |
| Master clinician | All of the above, plus create psychologist and administrator accounts, reset their passwords, stop or restore them, invite patients for and move patients to any psychologist, and install server updates from Settings | Reset their own or another master's password (that's `accounts.sh`) |
| Practice administrator, OpenWorks support | See names only. Invite a patient for a chosen psychologist, reset patients' passwords, stop or restore patients, move a patient to another psychologist. Both can install server updates from Settings. | See check-ins, scores, notes or watch data; create psychologist accounts (that would let them open patient data) |

Every one of these actions is in the audit log, and the psychologist is told when someone else
resets their patient's password or moves a patient. Psychologists and administrators **must use
two-step sign-in** (a 6-digit code from Aegis, 2FAS, Google or Microsoft Authenticator) unless
`STEADY_REQUIRE_2FA=off`; until they set it up, their account can't see anything.

Rate limits and the trusted proxy header are set by migrations; `accounts.sh check` shows them.
For an emergency, `STEADY_DASHBOARD=on` in `.env` (then `docker compose up -d`) reopens `/_/`
behind the SSH tunnel; it still needs a superuser, which only `accounts.sh` can make. Close it
again afterwards.

## 6. Server hardening

Do these on the VPS before real patient data arrives:

- [ ] SSH with keys only (`PasswordAuthentication no`, `PermitRootLogin no`).
- [ ] Firewall: only 22 (ideally limited to your address or a VPN), 80 and 443 open.
- [ ] Automatic security updates (`unattended-upgrades` on Debian/Ubuntu).
- [ ] Docker's data on an encrypted volume (LUKS), or full-disk encryption if the provider supports it.
- [ ] `chmod 600 deploy/.env` and keep `deploy/secrets/` readable only by root and the relay (uid 65532).
- [ ] `sudo ./accounts.sh check` says the dashboard is closed; `accounts.sh list` shows two-step sign-in for every staff account.
- [ ] Delete any permanent superuser left from before (`docker compose exec pocketbase /pb/pocketbase superuser delete <email> --dir=/pb/pb_data`).
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

**5. Accounts.** With `sudo ./accounts.sh`, as in step 5 above: the master clinician first.

**Updating** is `sudo ./update.sh` in `/opt/steady/deploy`, or from the app (below).

**6. Updates from the app (optional).** Lets psychologists you trust check for and install
updates from Settings > Server and updates, the way Shap does; the server also checks every night.

```bash
sudo /opt/steady/deploy/ctl/install.sh
```

The master clinician and administrators can use it straight away; for another psychologist, `sudo ./accounts.sh set <email> server-admin on`. The app
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
