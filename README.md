# Steady

Between-session check-ins for a psychology practice. One app, two kinds of login:

- **Patients** do a quick daily check-in (mood, anxiety, sleep and energy on a 1 to 5 scale, plus a few words), and complete the questionnaires and exercises their psychologist sends them.
- **Psychologists** see their patients at a glance, send questionnaires or exercises (once, daily or weekly), and get a notification when a patient checks in or finishes something.

Built by [OpenWorks IT](https://openworks.co.za). Free software under the GNU AGPL v3 or later.

> **Status: first build, not yet in clinical use.** Server logic is covered by automated tests, the real server boots cleanly in CI, and the app passes analysis and unit tests; nothing has run on phones yet. See [docs/TESTING.md](docs/TESTING.md) for exactly what has and hasn't been verified.

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
- **Access is narrow.** Patients see only their own data; psychologists see only their own patients. Every time a psychologist reads patient data it is written to an audit log.
- **No Google by default.** Android uses UnifiedPush (for example with the free ntfy app); iOS uses Apple's service directly.
- **Self-hosted in South Africa.** See [docs/PRIVACY.md](docs/PRIVACY.md) for POPIA notes.

## Quick start

```bash
# server
cd deploy
cp .env.example .env        # fill in the domain, practice name, Apple keys
./gen-keys.sh               # paste the printed values into .env
docker compose up -d --build
# then open https://<your-domain>/_/ from an allowed address, create the superuser,
# and add each psychologist in the users collection with role=clinician and active ticked

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
