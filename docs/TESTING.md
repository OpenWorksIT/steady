# What has been tested

Every push to GitHub runs all of the automated tests below (`.github/workflows/ci.yml`). A
change isn't released until they pass.

## Automated

**Server logic** (`node --test server/tests/*.test.js`, about 60 tests)

- Scoring for every built-in questionnaire (PHQ-9 with every band boundary and the item 9 flag,
  GAD-7, WHO-5, PCL-5 with its clusters); answers outside the allowed options rejected;
  clinician-built questionnaires, conditional items, FHIR and ReproSchema imports.
- Check-ins, the SAST day boundary, repeats, review flags (item 9, high bands, low mood three
  times in a row, missed days) and their stable keys for "marked as reviewed".
- Watch data: the daily summaries, usual ranges, consent and withdrawal; RADR: baselines, the
  four domains, exclusions per patient, levels for the patient list.
- **The real hook files and migrations** against an in-memory imitation of PocketBase: invites,
  joining, notifications with no patient data, the patient list order (most concerning first,
  stable last, archived off), notes, patient settings, the five kinds of account and who may
  reset, stop and restore whom, OpenWorks seeing no patients, the audit report, feedback tickets,
  app versions and watch permissions, exports (flag reviews, notes, methods, the Heidi series),
  and staff sign-in: device links with emailed codes (wrong, reused and expired codes), "confirm
  it's you", locking your own account, password resets unlinking devices, PocketBase's own email
  routes closed; browser tab sessions (short tokens, renewed as short ones whatever device key
  comes with them; phones and patients keep the usual length); the operator agreement (only the
  master clinician signs, only the version shown, every field checked, signed copies never
  change) and its text, version and docs copy agreeing.

**Push relay** (`cd pusher && go test ./...`): Web Push encryption against an independent
decryption, ES256 signatures and key formats, APNs requests against a local HTTP/2 server, the
`/send` endpoint.

**The real server** (CI's `e2e` job: the Docker test stack with PocketBase, the relay, Caddy and a
mail catcher):

- `deploy/test/security.py`, about 290 adversarial checks: what each kind of account must not
  reach (other patients, other psychologists' patients, hidden fields, the collections API, the
  dashboard, superuser routes), the reset and lock-down rules, OpenWorks seeing no patients,
  two-step sign-in (replayed codes, recovery codes), linked devices (codes, tickets, tries,
  removal, keys never returned), "confirm it's you" on every sensitive route, browser tab
  sessions (an hour, renewed as short ones, a copied token can't be made long; run against a
  server with a short `STEADY_TAB_SESSION_MINUTES` and the same value in the script's
  environment, it also waits for one to run out), locking your own account, closed PocketBase
  email routes, no patient names in any email sent, and the operator agreement (who reads, signs
  and opens it; signed copies can't be changed or deleted, not even by a superuser).
- `deploy/test/smoke.py`, the whole clinician and patient flow (starting with the master clinician
  signing the operator agreement), ending with the rate limits.
- Moving the test stack's data to a vps1-style production setup and signing in there.

**The app** (`flutter analyze` and `flutter test` in `app/`, and an Android build): data parsing,
server addresses and invite links, the watch summaries, chart periods, the patient words and
calm transitions, the feedback trail, layout rules, the exports (PDF report, Excel workbook,
Heidi PDF for a full export, a part of a series and chosen dates), the operator agreement's
text, Schedule and PDF, the screen lock (patients' Lock Steady off by default, the crisis numbers
on its lock screen, two minutes away; staff locked at opening) and when a browser tab's session
is renewed.

## Tested by people

- Beta 1 and Beta 2 at VR Clinical Psychology: Android (Samsung and others, with Health Connect),
  iPhone through TestFlight, and the web app.
- The Heidi export, with a fictional patient (Demo C) in Heidi itself: Heidi kept to the wording
  and got every fact right; its two suggestions (flag review status, linking the Heidi patient
  profile) are in 1.0.

## Before each release

1. On a test server, sign in as a psychologist on a new phone: the emailed code links it; the app
   locks after two minutes in the background and unlocks with the screen lock.
2. Reset a patient's password: the app asks to confirm it's you first.
3. As a patient on a phone, turn on Lock Steady in Settings, leave the app for two minutes and
   come back: it asks for the screen lock; cancel it: the crisis numbers show. Open the app
   switcher: Steady's picture is blank (also as a psychologist, and on an iPhone).
4. In a browser as a psychologist, keep the tab open for over an hour and use it: still signed
   in. Close the tab and open the site again: the sign-in screen.
5. Invite a patient on another phone, check in with mood 1, send and complete a PHQ-9 with item
   9 above 0: the notification shows no name or scores; the flag appears; mark it as reviewed.
6. Export for Heidi twice: the second offers "since the last export" and says part 2.
7. As the practice admin: the patient list shows status only. As OpenWorks support: no patients.
   On a fresh test server, the master clinician is asked to sign the operator agreement first;
   Settings > The practice > Operator agreement then shows it and downloads the PDF.
8. "Lost your phone? Lock your account" on the sign-in screen, then restore it as OpenWorks.
9. `./backup.sh` and a restore to a scratch machine.
