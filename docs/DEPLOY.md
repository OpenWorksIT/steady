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
3. **Settings > Rate limits**: enable them. Suggested: `/api/steady/join` 5 per minute per IP, `*:auth` 10 per minute.
4. **Collections > users**: create each psychologist with `role = clinician`, `active` ticked, a name and email. Ask them to reset their password from the app.
5. Optional, recommended: **users > Options > Multi-factor authentication** for clinicians.

Patients never get accounts from the dashboard; psychologists create invite codes in the app.

## 6. Backups

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

## 7. Updating

```bash
cd /opt/steady && git pull
cd deploy && docker compose up -d --build
```

Migrations run automatically on start. Take a backup first.

## Troubleshooting

| Symptom | Check |
|---|---|
| No notifications on iPhone | `docker compose logs pusher` for `apns 403` (wrong key/team) or `400 DeviceTokenNotForTopic` (`APNS_TOPIC` must equal the bundle id). Debug builds from Xcode use the APNs sandbox automatically. |
| No notifications on Android | The phone needs a UnifiedPush distributor app (e.g. ntfy) installed and chosen in Steady's settings. |
| "Can't reach the server" in the app | The app was built with the wrong `STEADY_SERVER`, or DNS/TLS isn't ready. |
| Psychologist can't sign in | `active` must be ticked and `role` set to clinician. |
