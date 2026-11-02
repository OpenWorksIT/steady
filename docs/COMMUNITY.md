# The Steady community forum

A private forum for psychologists at practices that use Steady, at
**community.steadyapp.co.za**. They talk about the science, build questionnaires together,
plan studies across practices, and shape how Steady develops. The first community is
VR Clinical Psychology (three psychologists). Kempie van Rooyen is the community lead.

It runs [Discourse](https://www.discourse.org) (free software, GPL v2) on its own small
server, separate from any practice's Steady server. It holds no patient data and is not
connected to Steady.

The kit is in `community/`:

| File | What it is |
|---|---|
| `community.yml.example` | The Discourse container settings: address, mail, and the hard rules pinned so no admin can switch them off by accident. |
| `community.caddy` | The forum's site for the Caddy in front of it (HTTPS). |
| `setup.py` | Sets up groups, categories, permissions, site settings and the welcome post through the Discourse API. Safe to run again. |
| `stats.py` | Prints the forum's activity counts for OpenWorks IT. Numbers only. |

## The rules

These hold for everyone, admins included.

1. **Invitation only.** Nobody can sign up on their own. You must be signed in to see anything.
2. **Password and authenticator code for every account.** No sign-in through Google, Facebook,
   Apple, Microsoft, GitHub or any other outside service. No emailed sign-in links.
3. **No patient-identifying information, ever.** No names, initials, dates of birth, ID or file
   numbers, contact details, or screenshots and photos of patient screens, exports or notes.
   No case details that together could point to one person. The welcome post says this first.
4. **Study data only as totals.** When practices run studies together, results are shared here
   only as aggregates (counts, averages), never as individual records. That work is for later.
5. **OpenWorks IT sees two areas only:** Announcements and Steady development. Everywhere else it
   sees only numbers (how many topics, posts and active members), never titles or text.

Rules 1 and 2, and the outside-services part of rule 5, are enforced by the forum's settings.
Rule 5 is enforced by category permissions. Rules 3 and 4 depend on the people posting; the
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

## Server

The forum runs on OpenWorks' own server, **vps3**, next to the fleet view and nothing else
([OPS-SERVER.md](OPS-SERVER.md): the server, hardening and the Caddy in front). Caddy does
HTTPS and passes the forum on to the Discourse container, `community`, on the `edge` Docker
network. Discourse publishes no ports of its own.

Discourse needs about 1 GB of memory while running and more while rebuilding
([INSTALL-cloud.md](https://github.com/discourse/discourse/blob/main/docs/INSTALL-cloud.md)).
vps3 has 4 GB and 2 GB of swap.

## 1. Before you start

- **The server**: [OPS-SERVER.md](OPS-SERVER.md), steps 1 to 3 (DNS for
  `community.steadyapp.co.za`, hardening, Caddy).
- **Mail**: the forum sends from `noreply@steadyapp.co.za`, the mailbox that already sends
  Steady's sign-in codes. Invitations, password resets and notifications come from it. Sign-in
  codes on the forum come from each person's authenticator app, not email. It needs the SPF,
  DKIM and DMARC records for steadyapp.co.za ([DEPLOY.md](DEPLOY.md), step 5a): add those
  first, or invitations land in spam.
- **The Steady repository** on your own computer, for `setup.py`.

## 2. Nothing more to prepare

Caddy, the `edge` network and swap are already there from OPS-SERVER.md.

## 3. Install Discourse

```bash
sudo git clone https://github.com/discourse/discourse_docker.git /var/discourse
```

Copy the settings file from the repository on vps3. Its name becomes the container's name, so
it must be `community.yml` (Caddy looks for `community`):

```bash
cd /var/discourse
sudo install -m 600 /opt/steady/community/community.yml.example containers/community.yml
sudo nano containers/community.yml       # the noreply mailbox password in DISCOURSE_SMTP_PASSWORD
sudo ./launcher rebuild community        # 10 to 15 minutes the first time
```

Caddy already has its site (`community/community.caddy`).

Check `https://community.steadyapp.co.za` shows a sign-in page with a padlock. It shows only
"Log in" (no "Sign up"), because the forum is invitation only.

**Mail port.** The file uses port 465 (SSL from the start). For port 587 with STARTTLS, change
it as the comment in the file says, then rebuild.

**Pinned settings.** The lines under "Hard rules, pinned" in `community.yml` fix those settings
and hide them from the admin pages. To change one, edit `community.yml` and run
`./launcher rebuild community`. That needs root on the server, which is the point.

**Real addresses.** Caddy passes each visitor's address on, and the forum believes it only from
Docker's private networks, so its sign-in limits count visitors, not Caddy.

## 4. Create the first admin

OpenWorks IT creates the first admin account, on the server, for the setup only:

```bash
cd /var/discourse
./launcher enter community
rake admin:create            # an OpenWorks address, a long password; answer Y to "grant Admin"
exit
```

Sign in at `https://community.steadyapp.co.za` with that account. The forum makes you set up
an authenticator app before you can do anything. Save the backup codes. If the setup wizard
opens, you can skip it: `setup.py` sets what matters.

## 5. Run setup.py

Make an admin API key for the script: **Admin > Advanced > API keys**, add a new key
(`/admin/api/keys/new`).

- Description: `setup.py (revoke after handover)`
- User level: **Single user**, your admin username
- Scope: **Global**

Copy the key. On your own computer, in the Steady repository:

```bash
export DISCOURSE_URL=https://community.steadyapp.co.za
export DISCOURSE_API_USERNAME=<your admin username>
read -rs DISCOURSE_API_KEY && export DISCOURSE_API_KEY    # paste the key; it isn't shown or saved

python3 community/setup.py --dry-run                   # shows what it would change
python3 community/setup.py --stats-account             # does it
```

It:

- creates the groups `clinicians` and `openworks`
- creates the five categories with the permissions in "Who sees what"
- closes every other category (Discourse's own General, Site Feedback and so on) to OpenWorks
  and to "everyone", and opens it to clinicians instead
- sets the site settings: invitation only, sign-in required, two-step sign-in for all, only
  admins send invitations, earlier versions of edited posts visible to staff only, permanent
  delete allowed, daily backups (seven kept), personal messages for both groups
- checks the pinned settings it can read back, and that no outside sign-in is enabled
- posts the welcome and guidelines topic in Announcements and pins it
- with `--stats-account`: creates the `openworks-stats` account and prints its key once (see
  "Activity counts for OpenWorks")

Run it again any time. It changes only what differs. Lines marked `WRONG` need fixing in
`community.yml`. To add a practice's private group and category at the same time, add
`--practice vr="VR Clinical Psychology"`.

## 6. Invite the psychologists

Kempie first. Signed in as admin: your avatar > **Invites** > **Invite**.

- Email: his address
- Add to groups: `clinicians` (and `practice-vr` if VR has a private category)
- Send

He accepts, chooses a username and password, and sets up his authenticator. His address is in
`DISCOURSE_DEVELOPER_EMAILS`, which Discourse uses to make an account admin when it signs up.
If his isn't (Admin > Users shows who is), grant it: **Admin > Users > his account > Grant admin**.

Then Kempie invites the other two VR psychologists the same way. From now on, only admins
send invitations.

## 7. Hand admin to Kempie

Once Kempie is an admin, **he** does these, signed in:

1. **Admin > Users** > the OpenWorks account > **Revoke admin** (and Revoke moderator, if shown).
2. **Groups > openworks > Add members**: the OpenWorks account. If it is in `clinicians`, remove it.
3. **Admin > Advanced > API keys**: **Revoke** the `setup.py` key. Leave the
   `openworks-stats` key (see below).

Check with OpenWorks signed in: the sidebar shows Announcements and Steady development only,
and a link to a clinical topic says the page doesn't exist or is private.

New OpenWorks staff: Kempie invites them into `openworks` only. OpenWorks' address is never in
`DISCOURSE_DEVELOPER_EMAILS` (an address listed there keeps some developer powers even
without admin).

Later admin work is Kempie's: in the browser, or by making a temporary Global key for himself
and running `setup.py`, then revoking it.

## Adding a practice

For each new practice:

1. **Admin > Groups > New group**: name `practice-<name>` (lower-case letters, digits and
   dashes, for example `practice-vr`), visible to members only.
2. **New category**: `<Practice name> (private)`. Under **Security**, remove "everyone" and give
   `practice-<name>` "Create / Reply / See". Nobody else.
3. Invite its psychologists into `clinicians` and `practice-<name>`.

Or with an admin key: `python3 community/setup.py --practice <name>="<Practice name>"`.

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

## Two-step sign-in, in practice

- Everyone sets up an authenticator app (Aegis, 2FAS, Google or Microsoft Authenticator) at
  their first sign-in and can't see anything until they have.
- Backup codes cover a lost phone. Keep them somewhere safe.
- Lost phone and no backup codes: an admin removes the person's two-step sign-in
  (Admin > Users > their account), after checking it's really them (for example by phone).
  They set it up again at their next sign-in.
- If the only admin is locked out, OpenWorks can do it on the server:
  `./launcher enter community`, then `rake "users:disable_2fa[<username>]"`.
- Passkeys are switched off (pinned), so every sign-in is password plus authenticator code.

## Troubleshooting

| Symptom | Check |
|---|---|
| No invitation or notification emails | `./launcher logs community`. Port 465 needs `DISCOURSE_SMTP_FORCE_TLS: true`; 587 needs STARTTLS and no FORCE_TLS. Keep the password in quotes. Admin > Emails > Logs shows what was sent. |
| No HTTPS certificate | DNS must point at vps3; then `docker compose -f ops/compose.yml logs caddy` in /opt/steady. |
| 502 from Caddy | The `community` container isn't running (`sudo ./launcher start community`), or isn't on the `edge` network (`docker network inspect edge`). |
| Rebuild stops with out-of-memory errors | Check swap is on (`swapon --show`). |
| A setting can't be changed in Admin | It is pinned in `community.yml`. Change it there and rebuild. |
| `setup.py` says HTTP 403 | Wrong key or username, or the key isn't Global, or it was revoked. |
| `stats.py` says the key was refused | The key was revoked, or the `openworks-stats` account was suspended or deleted. |
