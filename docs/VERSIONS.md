# Steady's versions

One number for the whole of Steady: the practice servers, the web app, the Android app on the
servers, and the store apps. It is set in `VERSION` at the top of the repository.

- **A large update adds .1**: 1.0.5 becomes **1.1.0**.
- **A small update adds .0.1**: 1.0.5 becomes **1.0.6**.
- **1.0.0** is the version VR Clinical Psychology's own server (vps2) started on, 30 October 2026.
  Everything before it was the beta, and counts as **0.9 and earlier**.

What people see:

| Where | Shows |
|---|---|
| A signed release, on a practice's server | `1.0.5` |
| Work on its way to a release (the test server, vps1) | `1.1.0 test 23`: heading for 1.1.0, 23 changes after the last release |
| The app (Settings, Server and updates) | its own version, the server's, the newest release, what's in testing, and the store apps |
| The fleet view | each server's version; a server from before versions shows its release's number when it runs the latest one |

`deploy/version.sh` works out the version of any commit the same way everywhere (CI, the
servers, the security check).

## Making a release

1. In a pull request into working: set `VERSION`, and the same number in `app/pubspec.yaml`
   (`version: 1.1.0+110`; the part after `+` doesn't matter, CI sets it). CI refuses the pull
   request if the two differ.
2. It goes through test (vps1) to main as usual.
3. On your own computer, once the "Test builds" run for main has finished: `deploy/release.sh`.
   It signs `v1.1.0` only if `VERSION` on main says 1.1.0, the number is higher than every
   release so far, and CI's web build of that commit is marked 1.1.0.

## The store apps

`app/stores.json` says which version each store has, and since when. Change it by hand when a
store approves a new version (`status`: `in review`, `live`, or `testing` for TestFlight). The
servers read it from main and show it under Settings > Server and updates, so it is there for
OpenWorks to keep track; it changes nothing else. Store builds take their version from
`VERSION` (Actions > Store builds, and iOS builds).

## So far

| Version | Date | What |
|---|---|---|
| 0.9 and earlier | 14 to 29 Oct 2026 | The beta: the first build, then the beta on a laptop test server, then on vps1 |
| 1.0.0 | 30 Oct 2026 | VR's own server (vps2). The 1.0 security audit and penetration tests, signed releases, the access log, exports for AI note-taking |
| 1.0.2 | 30 Oct 2026 | Patients can ask to delete their account in the app; the source code link and credits (1.0.1 was never released on its own) |
| 1.0.4 | 3 Nov 2026 | Fixes from the November security review; patients agree again when the consent statement changes; the fleet view (1.0.3 was never released on its own) |
| 1.0.5 | 3 Nov 2026 | Server updates from the app fixed; branches main, test and working; Caddy pinned; the dependency check |
| 1.1.0 | 5 Nov 2026 | The operator agreement, Android notifications through Google, live security and privacy checks in the fleet view, the Community tab, version numbers, Settings as a page |
| 1.1.1 | 6 Nov 2026 | Changing your own email address; the fleet view flags a server whose security check isn't running, and which code OpenWorks' own services run (the sign-in bridge against the fleet view's release); OpenWorks opens the community only from its own server, and reads The science |
| 1.2.0 | 7 Nov 2026 | The fleet view's admin and dev sign-ins, with server changes over SSH only; password resets from the fleet (the practice emails a code); the community run from the fleet view (the master clinician adds people, OpenWorks approves); patients check in and answer without signal |
| 1.2.2 | 7 Nov 2026 | Servers the fleet view switched the community on for read that setting again, so the Community tab is back; a practice with nobody approved stays off the sign-in bridge's list instead of the bridge refusing every practice the fleet view runs; the fleet view says when a server still reports the community off (1.2.1 was never released on its own) |
| 1.2.3 | 12 Nov 2026 | Says on the sign-in screen and in Settings that Steady is not a medical device and doesn't diagnose, treat, cure or prevent any condition, as Google Play asks of health apps; the watch screen says Steady measures nothing itself |
| 1.2.4 | 16 Nov 2026 | Patients see the watch data they shared, the same daily charts their clinician sees (tap the watch card on the home screen, or Settings > See your watch data); Health Connect's "why does Steady need this" opens a page saying what each data type is for, where it shows and how it helps, with the privacy notice (Google Play's Health Connect review) |
| 1.2.5 | 18 Nov 2026 | Steady is on Google Play and the App Store (1.2.4, live since 18 Nov 2026): invite QR codes send Android phones to Google Play and iPhones to the App Store; practice servers no longer offer the Android download, and its old address says Steady is on Google Play, so copies installed from a server are sent there. Only the test server keeps its own build and a TestFlight link |
| 1.2.6 | 18 Nov 2026 | One address, one practice in the community: the fleet view won't approve an address another practice already approved, and an address on two lists comes off them while everyone else carries on (before, the sign-in bridge set aside every practice the fleet view runs); Caddy on practice servers runs as a user of its own instead of root; the security check shows how the provider protects the disk at rest, from `STEADY_DISK_AT_REST` in `.env`, instead of warning about LUKS |
| 1.2.7 | 19 Nov 2026 | The front door: every service counts what it turned away (probes, the closed dashboard, failed sign-ins, rate limits, refusals), and the fleet view shows it all on a Front door page, flagging jumps; tripwires, decoys of each server's own that nobody at the practice touches, shown in red and emailed to OpenWorks when touched (docs/FRONTDOOR.md); Caddy really closes the dashboard and superuser sign-in (before, only PocketBase did); `robots.txt` keeps search engines off practice servers; Caddy 2.11.8 (security fixes) and Alpine 3.24.4 under the server |
| 1.2.8 | 20 Nov 2026 | Tripwire touches can be looked into and marked on the fleet view: each has a page with what happened (where the decoy was found, the request in full, the answer, the account kind), what it suggests, where it came from, and what else that address did on the server (from its request log, accounts only counted); mark it as a test, a scanner or real and dealt with, with a note, and it stops counting as red. The fleet view keeps its own copy of every touch. A touch is written to the database at once (before, a restart within the minute could lose it). The front door counts failed sign-ins, rate limits and refusals again (in 1.2.7 they always read 0 on a real server). The security check no longer warns about the tripwires file on a server where it is right (it read the server's group by name, which the host doesn't have) |
| 1.3.0 | next | From Kempie van Rooyen's review. **RADR**: a clinician can start a patient's baseline again from a chosen day (Patient settings), for someone who joined at a bad time in their life: from then on each day is compared only with data from that day on, days before keep their rating, and it shows with who and why wherever RADR does, exports included. **Contact consent**: a tick box right above the agree button, ticked to start with, asks whether the practice may contact the patient about what they share in Steady; patients who joined earlier are asked once, change it in Settings, and their clinician and the practice admin see the answer. **Daily words**: reworded so none predicts how someone will feel, breathing and body prompts offered as a choice with an alternative, and patients can hide a line or switch the words off. **Mental healthcare, not only psychologists**: the app, server, forum and docs say clinician (the consent statement too, so patients agree to it again once, on the same screen as the contact question; the privacy notice is privacy-5). App updates: pocketbase 0.26.0, flutter_zxing 3.1.1 |
