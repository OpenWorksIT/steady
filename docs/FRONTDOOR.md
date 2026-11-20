# The front door and tripwires

What Steady's servers turn away, and decoys that only an intruder would touch. Both report to
OpenWorks' fleet view (its **Front door** page, the overview and Checks), never to anyone in the
app. Since 1.2.7; touches can be looked into and marked since 1.2.8.

## What's counted

Each practice server counts the requests it turns away, by kind, for every hour
(`server/pb_hooks/lib/frontdoor.js`):

| Kind | What it is |
|---|---|
| probe | a path that isn't Steady's: not the web app's files, not its API (`/wp-login.php`, `/.env`) |
| closed door | PocketBase's dashboard or superuser sign-in, which are closed from outside |
| failed sign-in | a wrong password or two-step code (not the normal "enter your code" step) |
| rate-limited | turned away for asking too often |
| refused | the API without signing in, refused or not found |
| an account's own | the same while signed in: an account asking for what isn't its own |

With each hour it keeps how many different addresses there were, the paths asked for most and,
for probes and the closed door, the tools they came with (their User-Agent). An address is
hashed with the server's own salt and cut to 6 hex digits, about 250 addresses to each, so none
can be read back. Nothing about patients is kept: a refused request from the app only adds to a
count. Hours are kept 30 days.

Not counted: the server's own health check from inside, and its security check
(`deploy/audit-server.sh`), which knocks on the closed doors with the monitor key.

In 1.2.7 failed sign-ins, rate limits, refusals and an account's own refusals always read 0 on a
real server: PocketBase hands its errors to the counting code wrapped (a GoError), and their
status was read as 500. Fixed in 1.2.8; probes and the closed door were counted all along.

OpenWorks' own services on vps1 (the sign-in bridge, the community forum, the fleet view) are
counted from the Caddy in front of them by `fleet/edge-frontdoor.py`, every 10 minutes: requests,
refused (401, 403), not found, rate-limited and errors. The forum's and the bridge's links carry
tokens, so their log keeps no paths and they are counted only; the fleet view's log keeps paths.

### On the fleet view

The **Front door** page has every service, the last 24 hours and 7 days, and what was asked for
most. A service is flagged (and listed on Checks to look at) when a kind's last 24 hours is at
least three times its daily average over the 6 days before, and above a floor, so a quiet server
going from 1 to 4 isn't news:

| Kind | Floor in 24 h |
|---|---|
| failed sign-ins | 30 |
| tries at the closed dashboard | 20 |
| an account's own refusals | 20 |
| rate limits | 50 |
| refusals | 200 (100 on vps1's services) |
| probes, or not found on vps1 | 300 |
| errors on vps1's services | 50 |

Probes are the internet's background noise: every server gets them. A jump is worth a look; a
steady trickle isn't.

### Setting up vps1's count

Once, after updating `/opt/steady-ops` to a release with it:

```bash
sudo install -m 644 /opt/steady-ops/fleet/edge-frontdoor.service /opt/steady-ops/fleet/edge-frontdoor.timer /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now edge-frontdoor.timer
```

It reads the Caddy container `shap-caddy-1` (change `EDGE_CADDY` in the service if it's another)
and writes `/var/lib/steady-fleet/edge-frontdoor.json` for the fleet view. Its own tally, with
the salt, stays root's in `edge-state.json`. `sudo systemctl status edge-frontdoor` says how the
last run went. The fleet view says so when the count stops coming.

The test server's own site sits behind the same Caddy, but it counts itself, so the fleet view
leaves it out of vps1's list.

## Tripwires

A tripwire is a decoy nobody at the practice ever touches: nothing in the app shows it or leads
to it. So whoever touches one is looking for a way in, or has something they shouldn't. A touch
answers as it otherwise would, so the visitor isn't told. It is kept with the front door (written
at once, so a restart can't lose it), shown in red on the fleet view and on Checks as something
to fix until someone looks into it and marks it, and emailed to OpenWorks.

**The code is public; the decoys aren't.** Steady's source is open (AGPL), so how tripwires work
is on GitHub for anyone to read. Which decoys a server has, and where, is not: each server's are
in `deploy/decoys/decoys.json`, on that server only (git ignores the folder), readable by root
and the server and nobody else. The code is deliberately general: any path, any key a request
carries, any sign-in name could be one. Someone who reads the code learns that a server may have
tripwires, not which, and every unusual thing they try might be one. It's the same as passwords:
the sign-in code is public, the passwords aren't.

There are three types:

- **path**: a path, or everything under one (ending in `/` or `*`). Listed in the server's
  `/robots.txt` (which also keeps search engines off the whole server), which people never read
  and scanners do.
- **value**: a made-up secret you plant somewhere on the server. The server keeps only its
  SHA-256 and looks for it in every request's keys (`Authorization`, the `X-Steady-*` keys and the
  like, query values) and in passwords given to sign in. Whoever uses it has read where you put it.
- **name**: a sign-in name nobody has.

The server ignores a decoy that would catch the practice's own traffic, and says so on the fleet
view: a path the app uses or a file of the web app, a value that is one of the server's real keys,
a name that belongs to a real account (checked again as accounts come and go).

### Setting them up

On each practice server, as root, in `deploy/`:

```bash
sudo ./decoys.sh path <path> "<label>"
sudo ./decoys.sh value "<label>"        # prints the value once: plant it, then forget it
sudo ./decoys.sh name <email> "<label>"
sudo ./decoys.sh list
sudo ./decoys.sh check                  # what the server makes of them
```

The server reads them again within a minute; no restart. Then add the address touches are
emailed to (it needs the server's email set up, step 5a in DEPLOY.md):

```bash
echo 'STEADY_ALERT_EMAIL=<OpenWorks address>' | sudo tee -a .env && sudo docker compose up -d
```

The security check (`audit-server.sh`) says how many are set, and warns when there are none.

### Choosing decoys

This file is public too, so it gives no examples to copy: decoys from the docs are the first
ones a careful reader would avoid. What makes a good one:

- **Where an intruder would look, and nobody else.** A value goes where someone with a copy of
  the server's files would find it: in `.env` among the real keys, in a file in a folder an
  intruder would go through. A path is one a scanner would want to follow. A name is one an
  intruder would guess.
- **Plausible.** A value with a name that sits naturally among the real ones around it, in the
  same shape as the real keys (`decoys.sh value` makes them so). A path that looks like something
  worth having.
- **Different on every server**, so one server's leaked list says nothing about another's.
- **A label that says where it is** ("in .env", "a file in /root"): when it's touched, the label
  in the email says what leaked.

### When one is touched

The email says which decoy, when, where it was found, the request, the address it came from and
the tool it said it was. On the fleet view, every touch on the **Front door** page opens its own
page (since 1.2.8), and the overview's red pill counts the touches nobody has looked into yet.

**What the touch's page shows:**

- **What happened**, as the server kept it: the decoy and where it was found (the path, which
  header, the query, the sign-in name or password), the request with its query (values that look
  like a key, a token or a code shown only by length; a decoy's value never), what the server
  answered, the host it asked for, the address, any forwarding it claimed, the tool it said it
  was, the names of the headers it sent (a fingerprint of the tool), and whether it came signed
  in: a staff account by its address, a patient's only as "a patient's account" (the server's own
  log, `docker compose logs pocketbase | grep tripwire`, says which).
- **What it looks like**: what the decoy's type means, and what the page can tell: the address is
  the one you're on, or signed in to the fleet view (one of us testing); it read `robots.txt`
  just before; it asked for the server by its address rather than its name (scanning); it claimed
  to be forwarded for another address; its network is a hosting company; it touched another
  server's tripwires too.
- **Where it came from**: the address's DNS name and its network, country and block (Team Cymru's
  lookup, over DNS; nothing else leaves the fleet view), and links to look it up yourself
  (GreyNoise says whether it's a known mass scanner).
- **What else it did on that server**, from PocketBase's request log (5 days unless changed):
  every request from the address, with the touches picked out. Requests made with an account are
  only counted, never what they asked for; the rest show the route with record ids taken out,
  files unnamed and key-like values masked. A server gives this only for an address that touched
  one of its tripwires in the last 30 days (`GET /api/steady/fleet/trail`, with the fleet key).
- **Other touches from the same address**, on every server.

**Marking it**, with a note that stays with the touch, by anyone who signs in to the fleet view:

| Mark | When |
|---|---|
| A test | one of us (setting up or checking the tripwires) |
| A scanner, nothing more | a path followed from `robots.txt` by something that scans everyone |
| Real: dealt with | someone was after this server, and it has been dealt with: say what was done (the note is needed). The trail is kept with it, as the server's request log lets go after a few days |
| Only add the note | still looking: it stays red, and shows "being looked into" |

A mark can also go on the other touches from the same address not looked at yet (one click for a
test that touched all three decoys). A marked touch stops counting as red; it can be reopened.
Every mark and note is in the touch's notes and the fleet view's audit log, with who and when.
The fleet view keeps every touch the servers list in `touches.json` in its data folder, so a
server that is broken into can't take its record back: 90 days, a year for one marked real. The
**Every touch kept** page lists them.

**What to do about one:**

1. **A path:** someone read `robots.txt` and followed it. Usually a scanner: GreyNoise and the
   network say so, and the trail shows `robots.txt` and the path and little else. A trail with a
   run at the sign-in or the closed door, or a jump in the front door's counts, is someone
   working at it.
2. **A name:** someone tried to sign in with it. Someone is guessing at this practice
   specifically, or has read where the name was planted.
3. **A value: treat it as a leak.** Whoever used it has a copy of where you planted it. Follow
   the operator agreement's breach plan (clause 10): change every real key that was in the same
   place (`gen-keys.sh`, then `docker compose up -d`), find how the file left the server, and, if
   there are reasonable grounds to think practice information was reached, tell the practice
   within 24 hours (clause 9.1). Put a new decoy in place of the old one.
4. **Signed in:** that account's sign-in may be in someone else's hands. Reset it (`fleet.sh
   reset`, or `accounts.sh` on the server) and ask its owner.

Touches aren't blocked automatically: on South African mobile networks many people share one
address, and a block could shut out a patient.

## Caddy and the closed door

Caddy hands the dashboard and superuser sign-in to `/api/steady/closed`, which counts it and
answers 404, so the request never reaches them. Before 1.2.7 a `respond` did this, after the
`handle` that passes everything else on. Caddy runs `handle` first, so the `respond` never ran
and only PocketBase's own refusal kept these out. A server behind another Caddy (vps1's test
server) needs `deploy/proxy/steady.caddy` copied into that Caddy's sites again.
