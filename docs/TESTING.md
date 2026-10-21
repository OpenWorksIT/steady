# What has been tested

## Automated (run in CI or locally)

`node --test server/tests/*.test.js` (35 tests)

- Every built-in instrument validates.
- Scoring for PHQ-9 (every band boundary, item 9 flag), GAD-7, WHO-5 (raw x 4), PCL-5 (total, cut-point, B/C/D/E clusters).
- Answers outside the allowed options, missing required answers and unknown keys are rejected or dropped.
- Clinician-built questionnaires validate and score; common mistakes produce readable errors.
- Conditional items (`showIf`) are only required when shown.
- Check-in validation, 14-day series including the SAST day boundary, repeat scheduling.
- Review flags: item 9, high bands, three low-mood check-ins in a row, missed days, waiting items, old results ignored.
- FHIR import, and ReproSchema import using the real PHQ-9, GAD-7 and PC-PTSD-5 files from the library.
- Watch data: date handling, value validation, merging uploads, the 28-day usual range (needs 7 earlier readings, excludes the day itself), consent gating and withdrawal.
- **The real hook file and migrations**, run against an in-memory imitation of the PocketBase JavaScript API: schema and seeding, invite and join (single use, expiry, consent required), check-in notifications, content-free push payloads, licence gate on sending, a clinician can't send to another clinician's patient, server-side scoring, patients not shown scores, daily repeats, the morning cron, self-started exercises, deactivation, creating/editing/importing/archiving instruments.

`cd pusher && go test ./...`

- Web Push encryption checked against an independent decryption implementation.
- ES256 JWT signatures verify; key parsing (PKCS#8, SEC1, PKCS#1).
- APNs request format and token expiry handling against a local HTTP/2 server.
- The `/send` endpoint: authentication, mixed providers, invalid token reporting, message clamping.

`deploy/test/smoke.py` (run by CI's `e2e` job against the real PocketBase, and runnable against your own test server): config, clinician sign-in, invite, join with and without consent, single-use codes, what a patient can see, check-in and its notification, licence gate, sending PHQ-9, refusing incomplete answers, server-side scoring and the item 9 flag, the overview, FHIR import, watch-data consent, upload, merge and usual range, the privacy acknowledgement, and stopping a patient's access.

`flutter test` in `app/`: data parsing, server address handling, the daily watch summaries (resting heart rate from sleep, sleep stages, Apple-style stage joining, oxygen units) and the clinician chart periods.

`.github/workflows/ci.yml` also boots the real PocketBase image with the migrations and hooks and checks it starts without errors and answers `/api/steady/config`, and runs `flutter analyze` and `flutter test` on the app. These run on GitHub as soon as the repository is pushed.

## Not yet tested

- **The app on devices.** It passes `flutter analyze` and its unit tests, and the Android APK and web app build in CI (`test-builds.yml`), but neither has been run on a phone yet. The iOS app hasn't been built (needs a Mac and an Apple Developer account).
- Real delivery through Apple and a UnifiedPush distributor.
- Reading real watch data through Health Connect on a phone (Samsung and others).
- Load, backups and restores on the production server.

## Manual test script (before first patient)

1. Create a clinician with `deploy/accounts.sh --test add-clinician ...` (or use the one start.sh made). Sign in on phone A and set up two-step sign-in.
2. Invite a patient; join on phone B with the code. Check the consent text and that phone A gets "joined".
3. Phone B: check in with mood 1. Phone A: notification arrives with no name or scores on the lock screen; Alerts shows the detail.
4. Phone A: send PHQ-9. Phone B: notification, complete with item 9 > 0. Phone A: result shows the red item 9 flag; patient never sees a score.
5. Send GAD-7 daily: tomorrow's copy appears the next morning.
6. Library: import PHQ-8 from ReproSchema; confirm it can't be sent until the licence is confirmed.
7. Build a custom questionnaire with a band and a flag; send and complete it.
8. Stop the patient's access; phone B is signed out at next refresh.
9. Check `deploy/accounts.sh --test audit --days 1` shows each read.
10. Run `deploy/backup.sh` and restore to a scratch machine.
