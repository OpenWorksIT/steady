# Steady

Between-session check-ins for a psychology practice. One app for Android, iPhone and the web:

- **Patients** do a quick daily check-in (mood, anxiety, sleep and energy on a 1 to 5 scale, plus a few words), complete the questionnaires and exercises their psychologist sends them, and see their own timeline.
- **Watch data (optional)**: patients can share a daily summary of heart rate, sleep, steps and blood oxygen from Health Connect or Apple Health. Psychologists see it against each patient's own usual range, and in RADR, a research view of how far a patient is from their own normal. Display only, no alerts.
- **Psychologists** see their patients most concerning first, send questionnaires or exercises (once, daily or weekly), keep short notes, mark flags as reviewed, and export a patient's record as a PDF, an Excel workbook or a text PDF for Heidi (only what's new since the last one).
- **The practice**: a master clinician and a practice admin manage accounts and see each patient's connection status (never their data); OpenWorks IT support looks after the server and sees no patients at all.

Built by [OpenWorks IT](https://openworks.co.za). Free software under the GNU AGPL v3 or later.

> **Status: version 1.0.** In use at VR Clinical Psychology after two beta rounds on Android, iPhone (TestFlight) and the web. Every push runs the server unit tests, the real server with adversarial security checks and an end-to-end flow, and the app's analysis, tests and Android build. See [docs/TESTING.md](docs/TESTING.md).

## What's in the box

| Folder | What it is |
|---|---|
| `server/` | [PocketBase](https://pocketbase.io) 0.40 with Steady's database schema, access rules, API routes and scheduled jobs (JavaScript hooks and migrations). All clinical logic lives in `server/pb_hooks/lib/core.js` and is unit-tested. |
| `pusher/` | A small push relay in Go (standard library only). Delivers notifications through Apple (iOS) and UnifiedPush (Android, no Google services). Firebase is supported but off by default. |
| `app/` | The Flutter app for iOS and Android. |
| `deploy/` | Docker Compose setup with Caddy for HTTPS, key generation and encrypted backups. |
| `docs/` | Deployment, app setup, questionnaire format, privacy notes and testing. |

## Questionnaires and exercises

Built in: **PHQ-9**, **GAD-7**, **PCL-5** and **WHO-5**, plus box breathing, 4-7-8 breathing, slow paced breathing, 5-4-3-2-1 grounding and a thought record.

Psychologists can also:

- **Create** their own questionnaires and exercises in the app (questions, answer scale, score bands, review flags).
- **Import** from the open [ReproSchema library](https://github.com/ReproNim/reproschema-library) (90+ validated instruments), from a FHIR Questionnaire file, or from a Steady JSON file.

Every instrument carries a licence status. Imported instruments wait as "Check licence" until a psychologist confirms the practice may use them; only cleared or practice-written instruments can be sent. WHO-5 ships under review because its CC BY-NC-SA licence has a non-commercial clause the practice should confirm. Copyright-protected entries in the library are blocked.

## Safety and privacy, by design

- **Not an emergency service.** Every patient screen shows crisis numbers (SADAG 0800 567 567, 112 from a mobile) and says the app isn't monitored around the clock. The practice should approve this wording.
- **Flags are review aids, not risk scores.** PHQ-9 item 9, low mood in three check-ins in a row, high scores and missed check-ins are highlighted for the psychologist to look at.
- **No patient data in push notifications.** Notifications only say there's something new. The app fetches detail over its own authenticated connection.
- **Patients don't see their scores.** Scores go to the psychologist.
- **Access is narrow.** Patients see only their own data; psychologists see only their own patients. Every time a psychologist reads patient data it is written to an audit log, which the master clinician and practice admin can read in the app.
- **Staff sign-in is layered.** Password, a code from an authenticator app, and a device linked with an emailed code; the phone app locks with the phone's own screen lock, and sensitive actions ask to confirm it's you. A lost phone can be locked from any device; only OpenWorks restores the account.
- **No Google by default.** Android uses UnifiedPush (for example with the free ntfy app); iOS uses Apple's service directly.
- **Self-hosted in South Africa.** See [docs/PRIVACY.md](docs/PRIVACY.md) for POPIA notes.

## Quick start

```bash
# server
cd deploy
cp .env.example .env        # fill in the domain, practice name, Apple keys
./gen-keys.sh               # paste the printed values into .env
docker compose up -d --build
sudo ./accounts.sh add-clinician "Name" email@practice --master   # see docs/DEPLOY.md, "Accounts"

# app
cd app
./scripts/setup_platforms.sh
flutter run --dart-define=STEADY_SERVER=https://<your-domain>
```

Full steps: [docs/DEPLOY.md](docs/DEPLOY.md) and [docs/APP.md](docs/APP.md).

## Tests

```bash
node --test server/tests/*.test.js     # scoring, flags, importers, and the full API flow
cd pusher && go test ./...             # encryption, signing, delivery
```

## Licence

Copyright (C) 2026 OpenWorks IT (Pty) Ltd. Licensed under the GNU Affero General Public License v3.0 or later; see [LICENSE](LICENSE). If you run a modified version for others over a network, you must offer them its source.

Questionnaire texts remain under their own terms; see each instrument's licence note.
