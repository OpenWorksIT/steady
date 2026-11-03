# Monthly upkeep and support

Once a month, in the first working week, for every practice server, vps1 and the shared pieces.
Each item says what to look at and when it's done. Commands run in `/opt/steady/deploy` as root
(`sudo -i`) unless they say otherwise.

## 1. Updates to what Steady is built on

Caddy, PocketBase, Go, the base images, the app's Dart packages and the GitHub Actions are pinned
in the repository. Nothing a practice server runs changes because someone else released something:
an update comes in as a pull request and goes the same way as Steady's own changes.

- [ ] Look at what's waiting:
  - Dependabot's pull requests into `working` (GitHub > Pull requests).
  - The latest "Dependency check" run (GitHub > Actions): its summary lists known vulnerabilities in the PocketBase and Caddy releases in use.
  - The [PocketBase](https://github.com/pocketbase/pocketbase/releases) and [Caddy](https://github.com/caddyserver/caddy/releases) release pages, for anything Dependabot can't see.
- [ ] For each update worth taking, in this order:
  1. Merge it into `working` once CI is green.
  2. Open a pull request from `working` into `test` and merge it once CI is green.
  3. vps1 updates from `test` ("Update now", or `sudo ./ctl/steady-ctl.sh update`). Use it there: sign in as a psychologist and as a patient, check in, send and complete a questionnaire, and look at the server log.
  4. Review it before it goes further:
     - Read the release notes.
     - The dependency check is green.
     - `sudo ./audit-server.sh` on vps1 shows nothing new.
     - The CI suites (security, penetration, smoke) passed on `test`.
     - For a big change (a new PocketBase minor version, a new Caddy major), a full security review.
  5. Only when Tiaan says so: a pull request from `test` into `main`, then `deploy/release.sh` on his own computer, then the practice servers update.
- [ ] Never update a practice server from anything but a signed release.

## 2. Each practice server

Most of this is on the fleet view (https://fleet.steadyapp.co.za): each server's security and
privacy checks run every 6 hours and show there, with the privacy numbers. The list below is
what to look at there, and what it can't see.

- [ ] The fleet view's Checks column: all clear, or each item explained or fixed. A check that has stopped running says so.
- [ ] Settings > Server and updates: on the newest signed release, last update succeeded.
- [ ] Settings > Server health: disk under 70 %, no memory or load trouble.
- [ ] Backups: last night's backup is there (`audit-server.sh` says so). Once a quarter, restore one to a scratch machine with `restore-data.sh` and open it.
- [ ] The operating system: automatic security updates on; if a reboot is waiting, reboot outside practice hours.
- [ ] The TLS certificate has more than 30 days left (`audit-server.sh`).
- [ ] Staff: everyone uses two-step sign-in (`sudo ./accounts.sh list`); accounts of people who left are stopped.
- [ ] The operator agreement: the current version is signed (`audit-server.sh`, the fleet view).
- [ ] Patients: the People screen shows nobody stuck on an older consent statement who still uses Steady; no deletion request older than 25 days.
- [ ] Feedback tickets: each one answered or planned (Settings > Feedback tickets).

## 3. vps1 (the test server, the fleet view and the forum)

- [ ] The same checks as a practice server, where they apply (it holds no real patient data).
- [ ] It follows `test` (`STEADY_TRACK=test` in `.env`) and is on its newest commit.
- [ ] Free disk: `sudo docker image prune -f` if it's filling up.

## 4. GitHub

- [ ] Security alerts: Dependabot, secret scanning and code scanning (the repository's Security tab).
- [ ] `deploy/github-settings.sh` (from your own computer) still reports the rulesets and the signing environment as set: running it again is harmless.
- [ ] Who has access: collaborators, deploy keys, installed apps, the repository's Actions secrets and variables.

## 5. The apps and the stores

- [ ] Google Play Console and App Store Connect: no policy warnings, no deadline coming (target SDK, privacy forms).
- [ ] TestFlight builds expire after 90 days: a current one for testers.
- [ ] Firebase: one service-account key per practice server; delete the keys of retired servers.
- [ ] The Apple push key is still valid.

## 6. Mail, DNS and domains

- [ ] DMARC reports (dmarc@steadyapp.co.za): any mail failing SPF or DKIM? After a few clean months, move the policy from `quarantine` to `reject`.
- [ ] Domain renewals coming up: steadyapp.co.za, openworks.co.za and each practice's own domain.
- [ ] The CAA records are still there.

## 7. OpenWorks' own computer

- [ ] `deploy/backup-repo.sh` has recent copies in `~/Backups/steady`.
- [ ] The signing key has an offline backup, and its passphrase is stored safely.

## 8. Paperwork

- [ ] "Steady: for a lawyer to confirm": anything new to add, anything answered.
- [ ] Sub-operators unchanged. If one changes, practices are told 30 days before (operator agreement, clause 7).
- [ ] The Steady privacy policy still matches what Steady does; its date is current.

## 9. Support

- [ ] What came in this month (feedback tickets, emails, calls): a question asked twice is a fix for the app or the docs.
- [ ] Note the date, who did the upkeep, and anything left open.
