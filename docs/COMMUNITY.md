# Steady Community

A private forum for psychologists at practices that use Steady: the **Community** tab in the
Steady app and web app. They talk about the science, build questionnaires together, plan studies
across practices, and shape how Steady develops. Practice administrators have the tab too, and
see only the Steady manual there. The first community is VR Clinical Psychology (three
psychologists). Kempie van Rooyen is the community lead.

Steady Community is built on [Discourse](https://www.discourse.org) (free software, GPL v2),
with Steady's own look and words in place of Discourse's ("How it looks" below). It runs at
community.steadyapp.co.za, on OpenWorks' own server, separate from any practice's Steady server.
It opens only inside Steady, signed in as whoever is signed in to Steady ("Signing in through
Steady" below). It holds no patient data, and nothing else passes between it and Steady.

The kit is in `community/`:

| File | What it is |
|---|---|
| `community.yml.example` | The Discourse container settings: address, mail, and the hard rules pinned so no admin can switch them off by accident. |
| `community.caddy` | The forum's site for the Caddy in front of it (HTTPS). |
| `signin/` | The sign-in bridge at signin.steadyapp.co.za: the forum trusts it, and it trusts a short note signed by a practice's Steady server. Go, standard library only. |
| `setup.py` | Sets up groups, categories, permissions, site settings, the welcome post and the look through the Discourse API. Safe to run again. |
| `run-setup.sh` | Runs `setup.py` on the forum's server in one go: a one-off key made, used and removed. |
| `brand/` | The look: logo, icons, share image, fonts (Barlow, Atkinson Hyperlegible Next) and the theme. |
| `test_setup.py` | Tests for `setup.py`'s look, against a stand-in for the Discourse API. |
| `stats.py` | Prints the forum's activity counts for OpenWorks IT. Numbers only. |

## The rules

These hold for everyone, admins included.

1. **Psychologists only, inside Steady** (and practice administrators, for the Steady manual
   only). The forum has no accounts of its own and no sign-up, and it doesn't open on its own
   in a browser: everyone comes in through the Community tab, as who they are in Steady.
2. **Steady's sign-in for everyone**: password, authenticator code and a linked device, at the
   person's own practice. No forum passwords. No sign-in through Google, Facebook, Apple,
   Microsoft, GitHub or any other outside service. No emailed sign-in links.
3. **No patient-identifying information, ever.** No names, initials, dates of birth, ID or file
   numbers, contact details, or screenshots and photos of patient screens, exports or notes.
   No case details that together could point to one person. The welcome post says this first.
4. **Study data only as totals.** When practices run studies together, results are shared here
   only as aggregates (counts, averages), never as individual records. That work is for later.
5. **OpenWorks IT sees three areas only:** Announcements, the Steady manual and Steady development. Everywhere else it
   sees only numbers (how many topics, posts and active members), never titles or text.

Rules 1 and 2, and the outside-services part of rule 5, are enforced by the forum's settings,
the sign-in bridge and the forum's Caddy site. Rule 5, and practice administrators' part of
rule 1, are enforced by category permissions. Rules 3 and 4 depend on the people posting; the
welcome post and the "If someone posts patient information" steps below back them up.

## Who sees what

| Area | Clinicians | Practice administrators | OpenWorks IT |
|---|---|---|---|
| Announcements | Read and reply | No | Read, post and reply |
| Steady manual (how to use Steady, with screenshots) | Read and reply | Read and reply | Read, post and reply |
| The science (how each part of Steady works and why, with references) | Read and reply | No | Numbers only |
| Clinical practice | Read, post and reply | No | Numbers only |
| Research and studies | Read, post and reply | No | Numbers only |
| Questionnaires and tools | Read, post and reply | No | Numbers only |
| Steady development | Read, post and reply | No | Read, post and reply |
| Tea room (introductions, the work and life around it; Discourse's General, renamed) | Read, post and reply | No | Numbers only |
| A practice's private category (optional) | That practice only | No | Numbers only |
| Personal messages | Their own | None | Their own, including ones clinicians send to OpenWorks |

Forum admins (the community lead) can see everything. Admins and moderators can always post in
Announcements.

**Practice administrators** (the `practice-admins` group) see the Steady manual and nothing
else: they read it and ask in its replies, which clinicians and OpenWorks read too. They can't
send personal messages: `setup.py` allows them to admins, moderators, clinicians and OpenWorks
only, and not by trust level (Discourse's default lets anyone at trust level 1 send them).

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
psychologists, practice administrators (the Steady manual only) and OpenWorks support. It opens
as whoever is signed in to Steady, with no second sign-in. Opened straight in a browser (a
bookmark, a link in an email), it shows "The Steady Community opens inside Steady" instead.

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
| Practice administrator, address on the practice's list | `practice-admins` only: the Steady manual |
| OpenWorks support, through the server marked `support`, address on the OpenWorks list | `openworks` only |
| Patients | No Community tab, and refused |
| Staff without two-step sign-in | Refused until they set it up in Steady |

Each sign-in is in the practice's access log (Settings > Practice > Audit report: "Signed in to the
community forum").

**Email addresses.** The bridge's settings list, for each practice, the addresses its
psychologists and practice administrators use (one list covers both; the role in Steady decides
which groups they join): its own domain (`@vrpsych.co.za`), or single addresses (always for
Gmail and other public mail services). OpenWorks support's addresses are listed one by one, and
come in only through the one server marked `support`, which OpenWorks alone runs. No address or
domain may be on two lists, and the bridge refuses to start if one is. So a practice can only
ever bring in its own people: it can't sign anyone in as another practice's psychologist, as
Kempie, or as OpenWorks. Someone who already has a forum account with their address carries on with it; if
their address moves to another practice's list, they leave the old practice's group, and if
their role in Steady changes (an administrator who becomes a psychologist, or the other way
round), their groups follow at their next sign-in.

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

**OpenWorks' own server** (the test server, the one marked `support` in the bridge's settings)
gets a fourth line, and no practice's server ever does:

```bash
STEADY_COMMUNITY_SUPPORT=yes
```

It's where OpenWorks IT opens the community. On every other server, OpenWorks' support account
gets no Community tab, the server won't sign it a note, and the bridge would refuse it anyway:
three locks, so a support account on a practice's server never reaches the forum.

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
- `name`: shown beside its psychologists' and administrators' names in the forum.
- `url`: the practice's Steady address.
- `emails`: its psychologists' and practice administrators' addresses, or its own domain (see
  "Email addresses" above).
- `openworks`: OpenWorks IT's support addresses, one by one.
- `support` (one server only): OpenWorks support comes in through this one, a server OpenWorks
  alone runs (the test server). Anyone who can make a support account there could come in as
  OpenWorks, so never a practice's.
- `groups` (optional): the practice's private group, e.g. `["practice-vr"]` (see "Adding a
  practice"), for its psychologists only: its administrators never join it.

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

`https://signin.steadyapp.co.za` should say "Steady Community opens inside Steady", with a
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

OpenWorks holds no admin account on the forum. For the setup it uses a one-off key made on the
server, and removes it afterwards. On the server, in the Steady checkout (`/opt/steady-ops`, or
`/opt/steady` while trying it out on vps1):

```bash
sudo community/run-setup.sh --dry-run      # shows what it would change
sudo community/run-setup.sh                # does it
```

Each run makes the key inside the forum's container, runs `setup.py` with it, and removes the
key again through the forum's API, whatever happened. Making the key starts the forum's app
once: a minute or two, with nothing on the screen meanwhile. `setup.py` then takes 2 to 4
minutes the first time, pausing now and then ("rate limited, waiting ... s"): the forum takes 60
admin requests a minute. Arguments go on to `setup.py`, for example `--stats-account` or
`--practice vr="VR Clinical Psychology"`.

(The API isn't a page in a browser, so the "inside Steady only" rule doesn't stop it; the key
does the guarding.)

It:

- creates the groups `clinicians`, `practice-admins` and `openworks`
- creates the eight categories with the permissions in "Who sees what" (the Tea room is
  Discourse's own General, renamed), and lists them in everyone's side menu (each member sees
  only the ones open to them)
- closes every other category (Discourse's own General and so on) to OpenWorks, practice
  administrators and "everyone", and opens it to clinicians instead. Discourse's own Site
  Feedback can't be closed (Discourse won't change who sees it), so it is deleted: feedback goes
  to Steady development
- sets the site settings: sign-in required, sign-in through Steady only, earlier versions of
  edited posts visible to staff only, permanent delete allowed, daily backups (seven kept),
  personal messages for clinicians and OpenWorks (not practice administrators)
- checks the pinned settings it can read back, and that no outside sign-in is enabled
- posts the welcome and guidelines topic in Announcements and pins it
- posts the first topics, from `community/topics/` ("The first topics")
- gives the forum the Steady Community look ("How it looks")
- with `--stats-account`: creates the `openworks-stats` account and prints its key once (see
  "Activity counts for OpenWorks")

Run it again any time. It changes only what differs. Lines marked `WRONG` need fixing in
`community.yml`. To add a practice's private group and category at the same time, add
`--practice vr="VR Clinical Psychology"`.

**Discourse's own welcome page.** Until the forum has an admin, its front page is Discourse's
"Congratulations, you installed Discourse!", even for someone signed in through Steady.
Kempie's first visit makes him admin, which ends it; `run-setup.sh` ends it too, so the forum
can be tried before he has been (the test server, for one).

**If a key is left behind** (the run was cut off before the end): once Kempie is admin,
**Admin > Advanced > API keys > setup.py > Revoke**; before that, on the server:

```bash
sudo docker exec community rails runner 'ApiKey.where(description: "setup.py").destroy_all'
```

(`docker exec community` runs one command in the forum's container and comes back, after a
minute or two. Don't paste several lines after `./launcher enter community`: that opens a shell
in the container, and the lines after it go to the wrong place.)

## 5. First visits

Kempie first: in Steady, **Community**. His address is in `DISCOURSE_DEVELOPER_EMAILS`, so his
account is made admin as he arrives. The other VR psychologists just choose Community too, and
so does VR's practice administrator, who lands in `practice-admins` and sees the Steady manual.
Nobody is invited; nobody chooses a forum password.

OpenWorks staff choose Community in Steady with their OpenWorks support account on the test
server (marked `support` in the bridge, `STEADY_COMMUNITY_SUPPORT=yes` in its `.env`, their
address on the OpenWorks list) and land in `openworks` only: Announcements, the Steady manual and
Steady development. They don't see the Science section, Clinical practice, Research and studies,
Questionnaires and tools or the Tea room. Their support accounts on practices' servers have no
Community tab. OpenWorks' address is never in
`DISCOURSE_DEVELOPER_EMAILS` (an address listed there keeps some developer powers even without
admin).

Later admin work is Kempie's, in the community, or by making a temporary Global key for himself
(Admin > Advanced > API keys) and running `setup.py`, then revoking it.

## The first topics

So that the first psychologists find a community rather than an empty forum, `setup.py` posts
the topics in `community/topics/<category>/`: the Steady manual (ten topics, step by step with
screenshots from `manual/images/`, uploaded with the post), the Science section (one topic per part of
Steady: the check-in, flags, each questionnaire, watch data, RADR, the patient list, the
exercises), and starters in every other category (a de-identifying checklist, introductions in
the Tea room, the reading list, how studies will work, how to report a problem, and more).

Each file is `# Title`, then optionally `<!-- steady: pinned -->`, `<!-- steady: wiki -->` or
both, then the post. Each is posted once, as the system user, and found again by an id made
from its file name. One already in the forum is left as it is there (someone may have edited
it); `--update-topics` replaces it with its file. `--skip-topics` leaves them all alone.

`community/drafts/` holds what isn't posted automatically: a welcome in Kempie's voice for him
to post himself, and the private message every new member gets (`welcome-message.md`, applied as
Discourse's welcome text).

The topics describe Steady 1.1 (the Community tab first ships in it). VR Clinical Psychology
signs off the science: Kempie reads the Science section before the community opens.

## How it looks

Steady Community looks like steadyapp.co.za, not like Discourse: the Steady mark and the name
"Steady Community" at the top, the site's paper, ink, teal and tide blue, Barlow for headings and
Atkinson Hyperlegible Next (made for low-vision readers) for reading, rounded buttons, and the
site's deep band at the foot of every page with the one rule: no patient-identifying
information, ever. The box members type in says the same. It follows a phone's or computer's
dark mode.

`setup.py` applies it from `community/brand/`, through the API:

| What | Where |
|---|---|
| The logo (light and dark), the small mark, the email logo, the icons, the share image | `brand/*.png`, uploaded into the logo and icon site settings |
| Colours | Two palettes in `setup.py` (`PALETTES`): "Steady Community" and "Steady Community, dark" |
| Fonts, styles, the footer | The theme "Steady Community" (`brand/theme/`), the default for everyone; Discourse's own themes are no longer offered to members |
| Words | `TEXTS` in `setup.py`: the box members type in, the welcome above the lists, and the places Discourse names itself |
| Discourse's own topics | Its welcome topic and admin guide are removed; its guidelines topic gets Steady Community's (`GUIDELINES_RAW`). Its terms and privacy topics stay (`/tos`, `/privacy`) |

Settings: `enable_powered_by_discourse` off (no "Powered by Discourse"), Discourse's tutorial
bot off, people shown by their names rather than usernames, and chat off: one place to talk,
topics and personal messages, which flags and the guidelines cover (switch `chat_enabled` on in
`setup.py` if the community wants it). Everyone's side menu lists the community's categories in
order, and the link to Discourse's kanban boards is hidden.

To change something, edit the file in `community/brand/` (or `PALETTES`, `TEXTS` in `setup.py`)
and run `setup.py` again: it changes only what differs, and the forum shows it at once. The
wordmarks and `og.png` were drawn from the mark and the two fonts; if the name changes, draw
them again the same way. `python3 community/test_setup.py` checks the script against a stand-in
for Discourse.

The fonts are under the SIL Open Font License (`brand/fonts/LICENSE-*.txt`). Discourse itself
is GPL v2; nothing in its source is changed, only its settings, theme and texts.

## Adding a practice

1. **Its Steady server:** a key and the three lines in its `.env` (step 2). For the web app's
   Community tab, a `steadyapp.co.za` address (see "Web addresses").
2. **The bridge:** its entry in `config.json`, with its own `id`, key and address list. The
   one list covers the practice's psychologists and its practice administrators.
3. **Optional, a private area:** `python3 community/setup.py --practice <id>="<Practice name>"`
   (with a key, as in step 4) makes the group `practice-<id>` and its category. Add
   `"groups": ["practice-<id>"]` to the practice's entry, and its psychologists (not its
   administrators) join the group as they arrive.

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
sudo docker exec community discourse enable_restore
sudo docker exec community discourse restore <file>.tar.gz
sudo docker exec community discourse disable_restore
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
`sudo docker compose -f community/signin/compose.yml up -d --build`. The fleet view checks that
the bridge runs exactly its release's code (`GET /version`; FLEET.md, "Which code runs where")
and flags it red when it doesn't: built from another folder, or not rebuilt after an update.

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
| No Community tab | The practice's server lacks one of the three `.env` lines (step 2), the key is under 32 characters, or `docker compose up -d` wasn't run after adding them. Only psychologists, practice administrators and OpenWorks support get the tab. |
| "The community isn't available" | The bridge's `config.json` is missing or wrong: `signin check` (step 2) says what. |
| "Your practice's Steady isn't set up for the community, or its key doesn't match" | The practice's `key` in `config.json` isn't the same as `STEADY_COMMUNITY_KEY` on its server, or the practice isn't in `config.json`. |
| "...sends people to ..., not here" | `STEADY_COMMUNITY_SIGNIN` on that server isn't `https://signin.steadyapp.co.za`. |
| "This address isn't on the community's list" | The person's Steady email isn't on their practice's list (or, for OpenWorks support, the OpenWorks list). Add it, or the domain. |
| "OpenWorks support comes in through OpenWorks' own server" | A support account opened Community on a practice's server; use the server marked `support`. |
| "OpenWorks IT opens the community from its own server" | The same, refused by the practice's server itself. On the test server, `STEADY_COMMUNITY_SUPPORT=yes` is missing from its `.env` (step 2). |
| No Community tab for OpenWorks support on the test server | `STEADY_COMMUNITY_SUPPORT=yes` isn't in its `.env`, or `docker compose up -d` wasn't run after adding it. |
| "The community didn't open here" in the web app | The practice's Steady isn't a `steadyapp.co.za` address, so the browser won't keep the forum's sign-in in the frame (see "Web addresses"). The phone app works. Or the server's Caddy has no `frame-src` for the forum (step 2). |
| A blank Community tab in the web app | The browser's console names the rule: `frame-src` in Steady's Caddy, or `frame-ancestors` in `community.caddy`. |
| "Congratulations, you installed Discourse!" in the Community tab | The forum has no admin yet: step 4, "Discourse's own welcome page". |
| The forum opens as a site of its own | `community.caddy` isn't the current one: copy it again and reload Caddy. |
| No notification emails | `./launcher logs community`. Port 465 needs `DISCOURSE_SMTP_FORCE_TLS: true`; 587 needs STARTTLS and no FORCE_TLS. Keep the password in quotes. Admin > Emails > Logs shows what was sent. |
| No HTTPS certificate | DNS must point at vps1; then Shap's Caddy log. |
| 502 from Caddy | The `community` container isn't running (`sudo ./launcher start community`), the bridge isn't (`docker compose -f community/signin/compose.yml ps`), or one isn't on the `community-edge` network (`docker network inspect community-edge`). |
| Rebuild stops with out-of-memory errors | Check swap is on (`swapon --show`). |
| A setting can't be changed in Admin | It is pinned in `community.yml`. Change it there and rebuild. |
| `setup.py` says HTTP 403 | Wrong key or username (`system`, with the key `run-setup.sh` makes), or it was revoked. |
| `run-setup.sh` sits for minutes at "Making a one-off key" | The forum's app is starting in the container, which is slow on a busy server; more than 5 minutes means it's short of memory (`free -h`). |
| `stats.py` says the key was refused | The key was revoked, or the `openworks-stats` account was suspended or deleted. |
