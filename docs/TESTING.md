# What has been tested

## Automated (run in CI or locally)

`node --test server/tests/*.test.js` (25 tests)

- Every built-in instrument validates.
- Scoring for PHQ-9 (every band boundary, item 9 flag), GAD-7, WHO-5 (raw x 4), PCL-5 (total, cut-point, B/C/D/E clusters).
- Answers outside the allowed options, missing required answers and unknown keys are rejected or dropped.
- Clinician-built questionnaires validate and score; common mistakes produce readable errors.
- Conditional items (`showIf`) are only required when shown.
- Check-in validation, 14-day series including the SAST day boundary, repeat scheduling.
- Review flags: item 9, high bands, three low-mood check-ins in a row, missed days, waiting items, old results ignored.
- FHIR import, and ReproSchema import using the real PHQ-9, GAD-7 and PC-PTSD-5 files from the library.
- **The real hook file and migrations**, run against an in-memory imitation of the PocketBase JavaScript API: schema and seeding, invite and join (single use, expiry, consent required), check-in notifications, content-free push payloads, licence gate on sending, a clinician can't send to another clinician's patient, server-side scoring, patients not shown scores, daily repeats, the morning cron, self-started exercises, deactivation, creating/editing/importing/archiving instruments.

`cd pusher && go test ./...`

- Web Push encryption checked against an independent decryption implementation.
- ES256 JWT signatures verify; key parsing (PKCS#8, SEC1, PKCS#1).
- APNs request format and token expiry handling against a local HTTP/2 server.
- The `/send` endpoint: authentication, mixed providers, invalid token reporting, message clamping.

`.github/workflows/ci.yml` also boots the real PocketBase image with the migrations and hooks and checks it starts without errors and answers `/api/steady/config`, and runs `flutter analyze` and `flutter test` on the app. These run on GitHub as soon as the repository is pushed.

## Not yet tested

- **The full API flow on a running PocketBase.** CI proves the real server starts with the migrations and hooks and serves `/api/steady/config` without errors; the invite-to-result flow has only been run against the imitation. Run the manual script below.
- **The app on devices.** It resolves its packages, passes `flutter analyze` with no issues and passes its unit tests in CI, but hasn't been built for or run on an iPhone or Android phone.
- Real delivery through Apple and a UnifiedPush distributor.
- Load, backups and restores on the production server.

## Manual test script (before first patient)

1. Create a clinician in the dashboard. Sign in on phone A.
2. Invite a patient; join on phone B with the code. Check the consent text and that phone A gets "joined".
3. Phone B: check in with mood 1. Phone A: notification arrives with no name or scores on the lock screen; Alerts shows the detail.
4. Phone A: send PHQ-9. Phone B: notification, complete with item 9 > 0. Phone A: result shows the red item 9 flag; patient never sees a score.
5. Send GAD-7 daily: tomorrow's copy appears the next morning.
6. Library: import PHQ-8 from ReproSchema; confirm it can't be sent until the licence is confirmed.
7. Build a custom questionnaire with a band and a flag; send and complete it.
8. Stop the patient's access; phone B is signed out at next refresh.
9. Check `auditlog` in the dashboard shows each read.
10. Run `deploy/backup.sh` and restore to a scratch machine.
