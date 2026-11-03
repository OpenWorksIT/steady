# The Steady community forum

A private forum for psychologists at practices that use Steady: the **Community** tab in the
Steady app and web app. They talk about the science, build questionnaires together, plan studies
across practices, and shape how Steady develops. The first community is VR Clinical Psychology
(three psychologists). Kempie van Rooyen is the community lead.

It runs [Discourse](https://www.discourse.org) (free software, GPL v2) at
community.steadyapp.co.za, on OpenWorks' own server, separate from any practice's Steady server.
It opens only inside Steady, signed in as whoever is signed in to Steady ("Signing in through
Steady" below). It holds no patient data, and nothing else passes between it and Steady.

The kit is in `community/`:

| File | What it is |
|---|---|
| `community.yml.example` | The Discourse container settings: address, mail, and the hard rules pinned so no admin can switch them off by accident. |
| `community.caddy` | The forum's site for the Caddy in front of it (HTTPS). |
| `signin/` | The sign-in bridge at signin.steadyapp.co.za: the forum trusts it, and it trusts a short note signed by a practice's Steady server. Go, standard library only. |
| `setup.py` | Sets up groups, categories, permissions, site settings and the welcome post through the Discourse API. Safe to run again. |
| `stats.py` | Prints the forum's activity counts for OpenWorks IT. Numbers only. |

## The rules

These hold for everyone, admins included.

1. **Psychologists only, inside Steady.** The forum has no accounts of its own and no sign-up,
   and it doesn't open on its own in a browser: everyone comes in through the Community tab, as
   who they are in Steady.
2. **Steady's sign-in for everyone**: password, authenticator code and a linked device, at the
   person's own practice. No forum passwords. No sign-in through Google, Facebook, Apple,
   Microsoft, GitHub or any other outside service. No emailed sign-in links.
3. **No patient-identifying information, ever.** No names, initials, dates of birth, ID or file
   numbers, contact details, or screenshots and photos of patient screens, exports or notes.
   No case details that together could point to one person. The welcome post says this first.
4. **Study data only as totals.** When practices run studies together, results are shared here
   only as aggregates (counts, averages), never as individual records. That work is for later.
5. **OpenWorks IT sees two areas only:** Announcements and Steady development. Everywhere else it
   sees only numbers (how many topics, posts and active members), never titles or text.

Rules 1 and 2, and the outside-services part of rule 5, are enforced by the forum's settings,
the sign-in bridge and the forum's Caddy site. Rule 5 is enforced by category permissions. Rules 3 and 4 depend on the people posting; the
welcome post and the "If someone posts patient information" steps below back them up.

## Who sees what

| Area | Clinicians | OpenWorks IT |
|---|---|---|
| Announcements | Read and reply | Read, post and reply |
| Clinical practice | Read, post and reply | Numbers only |
| Research and studies | Read, post and reply | Numbers only |
| Questionnaires and tools | Read, post and reply | Numbers only |
| Steady development | Read, post and reply | Read, post and reply |
| A practice's private category (optional) | That practice only | Numbers only |
| Personal messages | Their own | Their own, including ones clinicians send to OpenWorks |

Admins (the community lead) can see everything. Admins and moderators can always post in
Announcements.

**Talking to OpenWorks.** Post in Steady development and mention `@openworks`, or send a
personal message to `@openworks` (the group) or to one of its people. A mention of `@openworks`
in a clinical category reaches nobody, because OpenWorks can't see it.

**The member list.** Every member, OpenWorks included, can see who the other members are
(names, usernames, profiles). Posts in categories someone can't see never show on profiles
or in search for them.

**Honestly, about the server.** Whoever has root access to a server can, in principle, read
its database. That is true of any hosted system, this one included. OpenWorks IT has that
access because it runs the server. What stops it is the hosting agreement and its
confidentiality terms, not the software. Forum permissions keep OpenWorks' *accounts* out of the
clinical areas. They can't keep out someone who reads the database directly.

## Signing in through Steady

The community opens only inside Steady: the **Community** tab of the app and the web app, for
psychologists (and OpenWorks support). It opens as whoever is signed in to Steady, with no
second sign-in. Opened straight in a browser (a bookmark, a link in an email), it shows "The
Steady community opens inside Steady" instead.

Each practice has its own Steady server, so the forum trusts OpenWorks' **sign-in bridge**
(`community/signin/`, at signin.steadyapp.co.za), through Discourse's own way of handing sign-in
to another site (DiscourseConnect). The bridge trusts only a short note signed by a practice's
Steady server:

1. Choosing Community, the tab asks the practice's Steady server for a note: who is signed in,
   signed with a key only that server and the bridge have. It is good for two minutes, once.
2. The tab opens the bridge with it. The bridge finds the practice whose key signed it, checks
   it, and sends the browser on to the forum.
3. The forum asks the bridge who is coming, and the bridge answers with the person from the note.
   They are in.

The forum is shown in a frame of the web app, and in a web view of its own in the phone app.
Each time the tab is opened the person signs in again, so the forum always shows whoever is in
Steady (another psychologist may have used the same computer). A forum session nobody uses ends
after 12 hours; signing out of Steady on a phone clears the community from the app too.

**What the forum gets:** the person's name and email address as Steady has them, their practice
(shown beside their name), an account number made of their practice and Steady account id
(`vr:abc123...`), and their groups. Never anything about patients, and never a Steady password or
code. The bridge keeps nothing: a sign-in under way is held in memory for two minutes at most.

**Who gets in:**

| In Steady | In the community |
|---|---|
| Psychologist, address on the practice's list | `clinicians`, and the practice's own group if it has one |
| OpenWorks support, through the server marked `support`, address on the OpenWorks list | `openworks` only |
| Practice admin, patients | No Community tab, and refused |
| Staff without two-step sign-in | Refused until they set it up in Steady |

Each sign-in is in the practice's access log (Settings > Audit report: "Signed in to the
community forum").

**Email addresses.** The bridge's settings list, for each practice, the addresses its
psychologists use: its own domain (`@vrpsych.co.za`), or single addresses (always for Gmail and
other public mail services). OpenWorks support's addresses are listed one by one, and come in
only through the one server marked `support`, which OpenWorks alone runs. No address or domain
may be on two lists, and the bridge refuses to start if one is. So a practice can only ever bring
in its own people: it can't sign anyone in as another practice's psychologist, as Kempie, or as
OpenWorks. Someone who already has a forum account with their address carries on with it; if
their address moves to another practice's list, they leave the old practice's group.

Kempie's address is the forum's developer address (`community.yml`): his account is made admin
when he arrives. Only VR's list covers it.

**When someone leaves.** The practice stops their Steady account, and with it their way in. Kempie
then ends any forum session they still have: **Admin > Users >** their account **> Log out** (a
session in daily use doesn't end on its own). Without Steady they can't come back.

## Server

The forum runs on **vps1**, behind Shap's Caddy, beside the fleet view ([FLEET.md](FLEET.md)).
Caddy does HTTPS and passes the forum on to the Discourse container, `community`, and the
sign-in bridge, `signin`, on the `community-edge` Docker network, which only those three share
(the fleet view has a network of its own). The bridge only answers browsers; it never talks to
the forum itself. Discourse publishes no ports of its own, and its Redis answers only inside the
container (`community.yml`).

Discourse needs about 1 GB of memory while running and more while rebuilding
([INSTALL-cloud.md](https://github.com/discourse/discourse/blob/main/docs/INSTALL-cloud.md)).
Keep swap on. The bridge needs a few MB.

**Web addresses.** In the web app the forum sits in a frame, which browsers allow with the
forum's sign-in only when the practice's Steady is a `steadyapp.co.za` address too
(`vr.steadyapp.co.za`, `test.steadyapp.co.za`). A practice on a domain of its own still has the
Community tab in the phone app. `community/community.caddy` lets any `*.steadyapp.co.za` page
frame the forum.

## 1. Before you start

- **DNS**: A records for `community.steadyapp.co.za` and `signin.steadyapp.co.za`, pointing at
  vps1.
- **The network**: `community-edge`, with Shap's Caddy on it, as for the forum already.
- **Mail**: the forum sends its notifications from `noreply@steadyapp.co.za`, the mailbox that
  already sends Steady's sign-in codes. It needs the SPF, DKIM and DMARC records for
  steadyapp.co.za ([DEPLOY.md](DEPLOY.md), step 5a).
- **The Steady repository** on your own computer, for `setup.py`.

## 2. The sign-in bridge

It holds the forum's secret and every practice's key, so it runs from a signed release in its
own folder, `/opt/steady-ops`, like the fleet view ([FLEET.md](FLEET.md), step 2: the code, its
signature checked). Until a signed release has the bridge, try it out from `/opt/steady` (vps1's
test checkout) instead, with the test server only, and move it before the forum goes live.

**Its settings folder**, readable only by the bridge, then the keys: build it and make one key
for the forum and one for each practice:

```bash
sudo install -d -m 700 -o 65532 -g 65532 /var/lib/steady-signin
cd /opt/steady-ops
sudo docker compose -f community/signin/compose.yml build
sudo docker compose -f community/signin/compose.yml run --rm --no-deps signin newkey   # once per key
```

**Each practice's Steady server** gets three lines in `deploy/.env`, then `sudo docker compose up -d`
in `deploy/`:

```bash
STEADY_COMMUNITY_URL=https://community.steadyapp.co.za
STEADY_COMMUNITY_SIGNIN=https://signin.steadyapp.co.za
STEADY_COMMUNITY_KEY=<that practice's key>
```

The server needs the Steady release that has the Community tab, and so does its web app. Its
Caddy must allow the frame: `deploy/Caddyfile` does (`frame-src`); a server behind another Caddy
(vps1, behind Shap's) needs `deploy/proxy/steady.caddy` copied there again.

**The bridge's settings**, `config.json` in that folder:

```bash
sudo nano /var/lib/steady-signin/config.json
sudo chown 65532:65532 /var/lib/steady-signin/config.json && sudo chmod 600 /var/lib/steady-signin/config.json
```

```json
{
  "url": "https://signin.steadyapp.co.za",
  "forum": "https://community.steadyapp.co.za",
  "forumSecret": "<the forum's key>",
  "openworks": ["tiaan@openworks.co.za"],
  "practices": [
    {"id": "vr", "name": "VR Clinical Psychology", "url": "https://vr.steadyapp.co.za",
     "key": "<VR's key>", "emails": ["@vrpsych.co.za"]},
    {"id": "test", "name": "Steady Test", "url": "https://test.steadyapp.co.za",
     "key": "<the test server's key>", "emails": ["<the test psychologist's address>"], "support": true}
  ]
}
```

- `id`: lower-case letters, digits and dashes. It is part of every forum account made through
  that practice: **never change it** once people have signed in.
- `name`: shown beside its psychologists' names in the forum.
- `url`: the practice's Steady address.
- `emails`: its psychologists' addresses, or its own domain (see "Email addresses" above).
- `openworks`: OpenWorks IT's support addresses, one by one.
- `support` (one server only): OpenWorks support comes in through this one, a server OpenWorks
  alone runs (the test server). Anyone who can make a support account there could come in as
  OpenWorks, so never a practice's.
- `groups` (optional): the practice's private group, e.g. `["practice-vr"]` (see "Adding a
  practice").

Changes are picked up within seconds; no restart needed. Check the file:

```bash
sudo docker compose -f community/signin/compose.yml run --rm --no-deps signin check
```

**Start it, and its Caddy site:**

```bash
sudo docker compose -f community/signin/compose.yml up -d
sudo cp community/signin/signin.caddy /opt/shap/deploy/vps/sites/signin.caddy
sudo cp community/community.caddy /opt/shap/deploy/vps/sites/community.caddy
cd /opt/shap/deploy/vps && sudo docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

`https://signin.steadyapp.co.za` should say "The Steady community opens inside Steady", with a
padlock.

## 3. Install Discourse

```bash
sudo git clone https://github.com/discourse/discourse_docker.git /var/discourse
```

Copy the settings file from the repository. Its name becomes the container's name, so it must
be `community.yml` (Caddy looks for `community`):

```bash
cd /var/discourse
sudo install -m 600 /opt/steady-ops/community/community.yml.example containers/community.yml
sudo nano containers/community.yml       # the two values marked CHANGE: the mailbox password, the forum's key
sudo ./launcher rebuild community        # 10 to 15 minutes the first time
```

`https://community.steadyapp.co.za`, opened in a browser, should go to the bridge's "opens inside
Steady" page.

**Already installed with forum passwords?** (vps1 was, before Steady sign-in.) Replace the
section under "Hard rules, pinned" in `containers/community.yml` with the one from
`community.yml.example`, fill in the forum's key, and rebuild. An account made before carries
on, posts and all, when its address is on its practice's list.

**Mail port.** The file uses port 465 (SSL from the start). For port 587 with STARTTLS, change
it as the comment in the file says, then rebuild.

**Pinned settings.** The lines under "Hard rules, pinned" in `community.yml` fix those settings
and hide them from the admin pages. To change one, edit `community.yml` and run
`./launcher rebuild community`. That needs root on the server, which is the point.

**Real addresses.** Caddy passes each visitor's address on, and the forum believes it only from
Docker's private networks, so its sign-in limits count visitors, not Caddy.

## 4. Run setup.py

OpenWorks holds no admin account on the forum. For the setup it uses a key made on the server,
and removes it afterwards:

```bash
cd /var/discourse && sudo ./launcher enter community
rake 'api_key:create_master[setup.py]'     # prints the key once
exit
```

On your own computer, in the Steady repository:

```bash
export DISCOURSE_URL=https://community.steadyapp.co.za
export DISCOURSE_API_USERNAME=system
read -rs DISCOURSE_API_KEY && export DISCOURSE_API_KEY    # paste the key; it isn't shown or saved

python3 community/setup.py --dry-run                   # shows what it would change
python3 community/setup.py --stats-account             # does it
```

(The API isn't a page in a browser, so the "inside Steady only" rule doesn't stop it; the key
does the guarding.)

It:

- creates the groups `clinicians` and `openworks`
- creates the five categories with the permissions in "Who sees what"
- closes every other category (Discourse's own General, Site Feedback and so on) to OpenWorks
  and to "everyone", and opens it to clinicians instead
- sets the site settings: sign-in required, sign-in through Steady only, earlier versions of
  edited posts visible to staff only, permanent delete allowed, daily backups (seven kept),
  personal messages for both groups
- checks the pinned settings it can read back, and that no outside sign-in is enabled
- posts the welcome and guidelines topic in Announcements and pins it
- with `--stats-account`: creates the `openworks-stats` account and prints its key once (see
  "Activity counts for OpenWorks")

Run it again any time. It changes only what differs. Lines marked `WRONG` need fixing in
`community.yml`. To add a practice's private group and category at the same time, add
`--practice vr="VR Clinical Psychology"`.

Then remove the key: once Kempie is admin, **Admin > Advanced > API keys > setup.py > Revoke**;
before that, on the server:

```bash
cd /var/discourse && sudo ./launcher enter community
rails runner 'ApiKey.where(description: "setup.py").destroy_all'
exit
```

## 5. First visits

Kempie first: in Steady, **Community**. His address is in `DISCOURSE_DEVELOPER_EMAILS`, so his
account is made admin as he arrives. The other VR psychologists just choose Community too.
Nobody is invited; nobody chooses a forum password.

OpenWorks staff choose Community in Steady with their OpenWorks support account on the server
marked `support` (their address on the OpenWorks list) and land in `openworks` only. OpenWorks' address is never in
`DISCOURSE_DEVELOPER_EMAILS` (an address listed there keeps some developer powers even without
admin).

Later admin work is Kempie's, in the community, or by making a temporary Global key for himself
(Admin > Advanced > API keys) and running `setup.py`, then revoking it.

## Adding a practice

1. **Its Steady server:** a key and the three lines in its `.env` (step 2). For the web app's
   Community tab, a `steadyapp.co.za` address (see "Web addresses").
2. **The bridge:** its entry in `config.json`, with its own `id`, key and address list.
3. **Optional, a private area:** `python3 community/setup.py --practice <id>="<Practice name>"`
   (with a key, as in step 4) makes the group `practice-<id>` and its category. Add
   `"groups": ["practice-<id>"]` to the practice's entry, and its psychologists join the group
   as they arrive.

## The test server in the community

While the community is being tried out, the test server (vps1) can be a practice in the
bridge's settings, so its test psychologist opens the Community tab like a real one and sees
what a psychologist sees:

```json
{"id": "test", "name": "Steady Test", "url": "https://test.steadyapp.co.za",
 "key": "<the test server's key>", "emails": ["<the test psychologist's address>"], "support": true}
```

Keep its list to the test account, so the test server can't sign anyone in as a real
psychologist. Before real clinical discussion starts, take its psychologist out again:

1. Remove the test psychologist's address from its `emails` (keep the entry while OpenWorks
   support comes in through it; `"emails"` can then list an OpenWorks-only address).
2. Admin > Users > the test account > **Log out** (and **Suspend**, if it should never come back).

## Activity counts for OpenWorks

OpenWorks can see how busy the forum is without reading it. `community/stats.py` prints one
line of JSON for the fleet view:

```json
{"at":"2026-11-01T09:30:00Z","users":4,"users7d":0,"users30d":4,"active1d":2,"active7d":3,"active30d":4,"participating7d":3,"participating30d":4,"topics":12,"topics7d":3,"topics30d":12,"posts":80,"posts7d":9,"posts30d":80,"likes":5,"likes7d":1,"likes30d":5,"chat7d":null,"chat30d":null}
```

Numbers only: never titles, names or text. `null` means this Discourse doesn't report that count.

**Where the numbers come from.** Discourse's `/about.json` has a `stats` block with
site-wide counts. Its fields are `topics_count`, `topics_7_days`, `topics_30_days`,
`posts_count`, `posts_7_days`, `posts_30_days`, `users_count`, `users_7_days`,
`users_30_days`, `active_users_last_day`, `active_users_7_days`, `active_users_30_days`,
`likes_count`, `likes_7_days`, `likes_30_days`, `participating_users_7_days` and
`participating_users_30_days`, plus `chat_messages_*` when chat is on. They count the whole
forum, private categories included: topics in every category (not personal messages), posts
including personal messages, members who are active and not suspended. Discourse works them out
about every 30 minutes, the same for everyone. `/about.json` also carries the site title and
the admins' names. `stats.py` reads only the numbers.

**Per category: not possible without reading access.** Discourse gives per-category counts only
for categories the account can see. So the counts stay site-wide.

**The key.** Signed-out visitors can't read `/about.json`, because sign-in is required. So
`stats.py` uses an API key that belongs to its own account, `openworks-stats`:

- A **bot account**: no email, no password, no groups. It can't sign in and sees no category.
  Bots don't count as members.
- A **granular** key with the single scope **badges: show**. Discourse allows every key to read
  `/about.json`, whatever its scope. A granular key needs at least one scope, and badges: show
  is the weakest one on offer (Discourse's public badge descriptions).

If the key leaked, someone could read the activity counts and the badge list, nothing else.

`setup.py --stats-account` makes both. By hand:

1. **The account.** Newer Discourse has a page for bot accounts, `/admin/users/bots/new`: username
   `openworks-stats`, trust level 0. On a Discourse without bot accounts, run
   `setup.py --stats-account --stats-email <an OpenWorks mailbox>`. It makes an ordinary
   account instead, with a random password nobody keeps (it then counts as one member).
2. **The key.** Admin > Advanced > API keys, add a new key (`/admin/api/keys/new`): description
   `openworks-stats (activity counts)`, user level **Single user**, user `openworks-stats`,
   scope **Granular**, tick **badges: show** and nothing else. Save and copy the key. It is
   shown once.

Run it:

```bash
DISCOURSE_STATS_KEY=<key> python3 community/stats.py
python3 community/stats.py --key-file /etc/openworks/community-stats.key   # chmod 600
```

Keep the key in the fleet view's secrets, never in git: the fleet view reads the same counts
itself from `community.json` ([FLEET.md](FLEET.md), step 5), so `stats.py` is for checking by hand. To replace it, make a new one
(`setup.py --stats-account --new-stats-key` or by hand), then revoke the old one in
Admin > Advanced > API keys. The community lead can see and revoke it there at any time.

`/site/statistics.json` would give the same counts to anyone, signed in or not. The pinned
`DISCOURSE_SHARE_ANONYMIZED_STATISTICS: false` closes it.

## If someone posts patient information

1. Anyone: flag the post, or send an admin a personal message. Don't quote it.
2. An admin: delete the post, then **permanently delete** it (`setup.py` turns permanent delete
   on), edit history included. Editing a post is not enough: earlier versions are kept.
3. It stays in that week's backups until they roll off (seven days on the server), and in any
   off-site copies until those are deleted. Tell OpenWorks, who deletes the affected off-site copies.
4. The practice decides whether it is a breach to report under POPIA (section 22). See
   [PRIVACY.md](PRIVACY.md).

## Backups

Discourse makes a backup every day (`setup.py` sets this) and keeps the last seven, in
`/var/discourse/shared/standalone/backups/default/` on the server. Each is one `.tar.gz` file
with the database and the uploads. **Admin > Backups** lists them and can make one now.

Copy them off the server, encrypted, like Steady's ([DEPLOY.md](DEPLOY.md), step 7). With
`age` and the public key in `/root/backup.age.pub`, a nightly root cron job:

```bash
40 4 * * *  cd /var/discourse/shared/standalone/backups/default && for f in *.tar.gz; do [ -e "/srv/offsite/$f.age" ] || age -R /root/backup.age.pub -o "/srv/offsite/$f.age" "$f"; done && find /srv/offsite -name '*.age' -mtime +30 -delete && rsync -a --delete /srv/offsite/ backup@<another SA server>:community/
```

Run `mkdir -p /srv/offsite && apt install -y age rsync` once. Make the age key pair on another
machine and keep the private half off this server. The job keeps 30 days of copies at most, so
a deleted slip doesn't linger.

Test a restore at least once, on a spare server set up the same way:

```bash
age -d -i backup-key.txt <file>.tar.gz.age > /var/discourse/shared/standalone/backups/default/<file>.tar.gz
cd /var/discourse && ./launcher enter community
discourse enable_restore
discourse restore <file>.tar.gz
discourse disable_restore
exit
```

## Updates

```bash
cd /var/discourse
git pull
./launcher rebuild community
```

Do it monthly, and soon after Discourse announces a security release (admins get an email).
The forum is offline for the 10 to 15 minutes the rebuild takes. **Admin > Upgrade** can also
update Discourse from the browser between rebuilds. Debian keeps itself patched through
`unattended-upgrades`.

The bridge comes with Steady's signed releases, like the fleet view ([FLEET.md](FLEET.md),
"Updating the fleet view"): check out the new release in `/opt/steady-ops`, then
`sudo docker compose -f community/signin/compose.yml up -d --build`.

## Two-step sign-in, in practice

- Everyone signs in with Steady, so Steady's two-step sign-in covers the forum: a psychologist
  without it set up in Steady is refused until they set it up.
- A lost phone is handled in Steady, as for Steady itself (the practice resets their two-step
  sign-in).
- The forum has no passwords or codes of its own to lose, and nothing to reset.

## Troubleshooting

The bridge says why it refused someone in its log, never with names or addresses:
`sudo docker compose -f community/signin/compose.yml logs --tail 50` (in `/opt/steady-ops`).

| Symptom | Check |
|---|---|
| No Community tab | The practice's server lacks one of the three `.env` lines (step 2), the key is under 32 characters, or `docker compose up -d` wasn't run after adding them. Only psychologists and OpenWorks support get the tab. |
| "The community isn't available" | The bridge's `config.json` is missing or wrong: `signin check` (step 2) says what. |
| "Your practice's Steady isn't set up for the community, or its key doesn't match" | The practice's `key` in `config.json` isn't the same as `STEADY_COMMUNITY_KEY` on its server, or the practice isn't in `config.json`. |
| "...sends people to ..., not here" | `STEADY_COMMUNITY_SIGNIN` on that server isn't `https://signin.steadyapp.co.za`. |
| "This address isn't on the community's list" | The person's Steady email isn't on their practice's list (or, for OpenWorks support, the OpenWorks list). Add it, or the domain. |
| "OpenWorks support comes in through OpenWorks' own server" | A support account opened Community on a practice's server; use the server marked `support`. |
| "The community didn't open here" in the web app | The practice's Steady isn't a `steadyapp.co.za` address, so the browser won't keep the forum's sign-in in the frame (see "Web addresses"). The phone app works. Or the server's Caddy has no `frame-src` for the forum (step 2). |
| A blank Community tab in the web app | The browser's console names the rule: `frame-src` in Steady's Caddy, or `frame-ancestors` in `community.caddy`. |
| The forum opens as a site of its own | `community.caddy` isn't the current one: copy it again and reload Caddy. |
| No notification emails | `./launcher logs community`. Port 465 needs `DISCOURSE_SMTP_FORCE_TLS: true`; 587 needs STARTTLS and no FORCE_TLS. Keep the password in quotes. Admin > Emails > Logs shows what was sent. |
| No HTTPS certificate | DNS must point at vps1; then Shap's Caddy log. |
| 502 from Caddy | The `community` container isn't running (`sudo ./launcher start community`), the bridge isn't (`docker compose -f community/signin/compose.yml ps`), or one isn't on the `community-edge` network (`docker network inspect community-edge`). |
| Rebuild stops with out-of-memory errors | Check swap is on (`swapon --show`). |
| A setting can't be changed in Admin | It is pinned in `community.yml`. Change it there and rebuild. |
| `setup.py` says HTTP 403 | Wrong key or username (`system` with a key from `rake`), or it was revoked. |
| `stats.py` says the key was refused | The key was revoked, or the `openworks-stats` account was suspended or deleted. |
