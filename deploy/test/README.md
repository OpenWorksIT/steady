# Steady test stack

Runs the Steady server on your PC and makes it reachable from phones through a Cloudflare tunnel. For testing only: no backups, test accounts, data stays on your PC.

## Needs

Docker with Compose v2, `curl`, `openssl`, `python3`, and the [GitHub CLI](https://cli.github.com) signed in (`gh auth login`) to fetch the web app.

## 1. A fixed address (recommended)

The app's live updates use Server-Sent Events, which Cloudflare's no-account quick tunnels don't carry. A named tunnel on your own domain also keeps the same address every time.

1. Cloudflare dashboard > **Zero Trust** > **Networks** > **Tunnels** > **Create a tunnel** > **Cloudflared**. Name it `steady-test`.
2. On the install screen, copy the **token** (the long string after `--token`). You don't need to install anything; Docker runs it.
3. **Public hostname**: subdomain `steady-test`, your domain, service type **HTTP**, URL `caddy:80`. Save.
4. Run `./start.sh` once (it creates `.env`), then edit `deploy/test/.env`:
   ```
   TUNNEL_TOKEN=<the token>
   PUBLIC_URL=https://steady-test.<your domain>
   ```

Skip this and `start.sh` uses a quick tunnel instead: a random `trycloudflare.com` address that changes each start, push notifications work, live in-app updates don't.

## 2. Start

```bash
cd deploy/test
./start.sh --update     # first time, and whenever you want the latest web app
./start.sh              # later starts
```

It prints the address, the clinician sign-in, and the dashboard login. Other commands: `--stop`, `--reset` (deletes all test data).

Check the server end to end at any time:

```bash
python3 smoke.py                    # against localhost
python3 smoke.py https://steady-test.<your domain>   # through the tunnel
```

## 3. Android

1. Download `steady-test.apk` from the repo's **Releases > Test build** (or `gh release download test-build -R OpenWorksIT/steady -p steady-test.apk`) and copy it to the phone. Allow installing from that source when asked.
2. Install **ntfy** from F-Droid or the Play Store and open it once. That's what delivers notifications, without Google.
3. Open Steady, enter the address, sign in. Allow notifications. Under Settings in the app, Notifications should say On.

## 4. iPhone (Friday)

A native iPhone build needs an Apple Developer account and Xcode on a Mac, so for now use the web version: open the address in **Safari**, tap **Share > Add to Home Screen**, and open Steady from the home screen. Everything works except lock-screen notifications; new items appear while the app is open.

## Trying both directions

- Clinician on one phone, patient on the other: the clinician taps **Invite**, the patient taps **I have an invite code** on the sign-in screen.
- Swap roles by signing out (Settings) and creating a second clinician in the dashboard (`users` collection, role `clinician`, active ticked).
