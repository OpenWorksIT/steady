# Privacy and POPIA notes

These are engineering notes to help the practice and its advisers. They are not legal advice.

## Roles

- The **practice** is the responsible party under POPIA. It decides why and how patient information is processed.
- **OpenWorks IT** hosts and maintains Steady for the practice and is an **operator**. Section 21 requires a written contract between them that obliges the operator to keep the information secure and confidential.
- Check-ins, questionnaire answers and notes are **health information**, which is special personal information (sections 26 to 33). Processing by health professionals under a duty of confidentiality for the patient's care is the usual basis (section 32); the practice should confirm this with its adviser and the HPCSA rules it follows.

## What the system does

| Requirement | How Steady handles it |
|---|---|
| Consent and openness | Patients read the practice's consent statement and tick to agree when they join. The version they accepted and when are stored on their account. |
| Minimality | Name, email, four ratings, optional free text, questionnaire answers. No location, contacts, or device data beyond a push token. |
| Access control | Patients see only their own data. Psychologists see only patients linked to them. Enforced by database rules on the server, not by the app. |
| Access logging | Every time a psychologist lists or opens check-ins or results, or loads the patient overview, it's written to `auditlog` with who, what and when. Only the superuser can read it. |
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

## Things to keep in mind

- The free-text box can contain anything, including disclosures of risk. The app says it isn't monitored around the clock; psychologists should agree how often they look.
- Patients' phones are outside the practice's control. Encourage a screen lock.
- Review the audit log periodically.
