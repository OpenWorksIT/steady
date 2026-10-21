# Privacy and POPIA notes

These are engineering notes to help the practice and its advisers. They are not legal advice.

## Roles

- The **practice** is the responsible party under POPIA. It decides why and how patient information is processed.
- **OpenWorks IT** hosts and maintains Steady for the practice and is an **operator**. Section 21 requires a written contract between them that obliges the operator to keep the information secure and confidential.
- Check-ins, questionnaire answers and notes are **health information**, which is special personal information (sections 26 to 33). Processing by health professionals under a duty of confidentiality for the patient's care is the usual basis (section 32); the practice should confirm this with its adviser and the HPCSA rules it follows.

## What the system does

| Requirement | How Steady handles it |
|---|---|
| First-launch notice | Everyone sees a plain-language privacy and POPIA notice (`app/lib/content/privacy_notice.dart`) before signing in. The version and time they acknowledged it are stored on their account. |
| Watch data | Optional and off by default. The patient sees exactly what is shared and agrees separately; that consent is stored with version and time, and they can withdraw it in Settings (uploads stop; what was shared stays in the record). Only daily summaries leave the phone. No alerts are raised from watch data. |
| Consent and openness | Patients read the practice's consent statement and tick to agree when they join. The version they accepted and when are stored on their account. |
| Minimality | Name, email, four ratings, optional free text, questionnaire answers. No location, contacts, or device data beyond a push token. |
| Access control | Patients see only their own data. Psychologists see only patients linked to them, plus any patient a colleague shared with them (read only, one patient at a time, and the patient can see who in Settings). Administrators and OpenWorks support see names only. Enforced by database rules on the server, not by the app. Stopping an account signs it out on every device at once. |
| Staff sign-in | Psychologists and administrators use two-step sign-in (password plus a code from an authenticator app). Used codes can't be replayed; eight one-time recovery codes cover a lost phone. |
| Password resets | Done by the patient's psychologist, the master clinician or the administrator, never by email. The reset gives a temporary password and signs the person out everywhere; until they choose a new one the account can't read or send anything, so whoever did the reset can't use it to look at the patient's data. Every reset is logged and the psychologist is told. |
| Exports | A psychologist can export their own patients' records (PDF report or Excel workbook) for the clinical file or a data request. Exports are logged. The file is then the practice's responsibility: keep it in the patient file, not in email or a downloads folder. |
| Sorted (practice software) | If the practice connects Sorted, it reads a treating psychologist's own patients' feed server to server with a key kept in each server's settings. Item-level answers are left out. Every read is logged on both sides. |
| No dashboard | PocketBase's built-in admin dashboard is switched off. Account work on the server goes through `accounts.sh`, which leaves no standing superuser behind. |
| Brute-force protection | Passwords of at least 10 characters. Sign-in, password reset and invite codes are rate limited per address. |
| Access logging | Every time a psychologist lists or opens check-ins or results, or loads the patient overview, it's written to `auditlog` with who, what and when. Nobody reads it in the app; OpenWorks prints it on the server with `accounts.sh audit` (for example for a patient's access request). Shared reads, exports, resets, moves and the Sorted feed are logged too. |
| Security in transit | HTTPS only (Caddy, automatic certificates, HSTS). |
| Security at rest | Encrypt the server's disk. Backups are encrypted with `age` before they're written. |
| Push notifications | No names, scores or text ever go to Apple, Google or UnifiedPush servers. |
| Retention | In-app notifications are deleted after 90 days (configurable). Clinical records (check-ins, results) are kept as part of the patient file; the practice decides the period under its record-keeping obligations. |
| Stopping | A psychologist can stop a patient's access; the account can't sign in and waiting activities are cancelled. Records stay for the file. |
| Location | Host in South Africa. Section 72 limits sending personal information abroad. |
| Phones | The session token is stored in the iOS Keychain / Android Keystore. Android backups of app data are disabled. |

## For the practice to do

1. Sign the operator agreement with OpenWorks IT.
2. Approve the consent statement in `server/pb_hooks/content/consent.md` and the crisis wording.
3. Register its Information Officer with the Information Regulator if it hasn't.
4. Decide retention periods.
5. Decide whether PHQ-9 (with item 9) or PHQ-8 is used between sessions, and how out-of-hours results are handled.
6. Keep a breach response plan (section 22 requires notifying the Regulator and patients).

## Watch data and research

If watch data is being collected to inform research (for example the design of Amon Dîn), the practice should confirm whether ethics approval and a research-specific consent are needed in addition to the in-app consent.

## Things to keep in mind

- **The test setup is not for real patient data.** Through a Cloudflare tunnel, Cloudflare decrypts the traffic at its edge (outside South Africa) and the server is a test PC. Move to the South African VPS before real patients are invited; see the security review.

- The free-text box can contain anything, including disclosures of risk. The app says it isn't monitored around the clock; psychologists should agree how often they look.
- Patients' phones are outside the practice's control. Encourage a screen lock.
- Review the audit log periodically (`accounts.sh audit`).
- Sharing a patient with a colleague is a disclosure inside the practice, for the patient's care. The consent statement should say that other psychologists at the practice may be given access for supervision or cover; the patient sees who in Settings.
