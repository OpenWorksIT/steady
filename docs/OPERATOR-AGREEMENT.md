> **Draft for review by an attorney; not legal advice.** This is OpenWorks IT's template of the
> operator agreement each practice signs in Steady. The text below, from the title to the
> Schedule, is word for word what the app shows (`server/pb_hooks/content/operator-agreement.md`);
> the notes after it are not part of the agreement. Have it reviewed before it is released to
> practices.

# Operator agreement for Steady

Version 1.0, November 2026

This agreement is between OpenWorks IT (Pty) Ltd ("OpenWorks") and the practice whose details are recorded in the Schedule when this agreement is signed ("the Practice"). It is the written contract that section 21 of the Protection of Personal Information Act 4 of 2013 ("POPIA") requires between a responsible party and its operator.

## 1. The parties

1.1 OpenWorks: OpenWorks IT (Pty) Ltd, registration number 2024/733128/07, of 24 Pelican Road, Port Elizabeth, 6070, South Africa. Email: info@openworks.co.za. Phone and WhatsApp: 076 768 9155. Information Officer: Tiaan van der Merwe, info@openworks.co.za.

1.2 The Practice: the practice named in the Schedule, with the registration or practice number, physical address and contact details recorded there when this agreement is signed.

## 2. Definitions

2.1 In this agreement:

- "Steady" is the free software (GNU Affero General Public License, version 3 or later) for between-session check-ins that OpenWorks makes: the apps and the server software.
- "The Server" is the Practice's own instance of the Steady server software, with its database, files and backups, which OpenWorks runs for the Practice.
- "The Service" is what OpenWorks does for the Practice under clause 3.2.
- "Practice Information" is all personal information that OpenWorks processes for the Practice through the Service, about patients and about the Practice's staff. "Patient Information" is the part of it that is about patients.
- A "Sub-operator" is anyone OpenWorks uses to process Practice Information for the Service.
- A "Security Compromise" is any event where there are reasonable grounds to believe that Practice Information has been accessed or acquired by an unauthorised person, or lost, damaged or destroyed without authority.
- "Information Officer", "personal information", "processing", "data subject", "responsible party", "operator" and "special personal information" have the meanings POPIA gives them.
- A "business day" is any day except a Saturday, a Sunday or a public holiday in South Africa.

## 3. Roles and scope

3.1 The Practice is the responsible party for Practice Information. OpenWorks is its operator.

3.2 OpenWorks provides the Service:

- hosting the Server on a virtual server in South Africa;
- maintaining it: operating-system and security updates, watching its health, and fixing problems;
- updating Steady to new releases;
- support for the Practice's staff, including setting up staff accounts, resetting staff passwords and restoring locked accounts;
- nightly encrypted backups, and restoring from them when needed; and
- sending Steady's account emails and push notifications for the Server.

3.3 OpenWorks does not provide clinical services, does not monitor what patients send, and does not decide what personal information the Practice collects or why. The Practice decides that, including in the consent statement it gives patients.

3.4 This agreement does not deal with fees. Those are in OpenWorks' quote or invoice for the Service. Steady itself has no licence fee.

## 4. Processing only on the Practice's instructions

4.1 OpenWorks processes Practice Information only with the Practice's knowledge or authorisation, and only to provide the Service.

4.2 The Practice's instructions are this agreement, the way the Practice's staff use Steady (its settings and the actions they take in the app), and any further written instructions from the Practice's master clinician or Information Officer.

4.3 OpenWorks never uses Practice Information for its own purposes, such as analytics or advertising, and never sells it.

4.4 If OpenWorks believes an instruction would break POPIA or another law, it tells the Practice, and need not carry the instruction out until the parties have agreed what to do.

4.5 If a law or a court requires OpenWorks to disclose Practice Information, OpenWorks tells the Practice first, unless the law forbids that, and discloses no more than is required.

## 5. Confidentiality

5.1 OpenWorks treats all Practice Information as confidential and does not disclose it, unless the law requires it or it is needed to provide the Service properly.

5.2 This binds OpenWorks' directors, employees and contractors. OpenWorks gives access to Practice Information only to people who need it for the Service and who are bound by a written duty of confidentiality that continues after their work for OpenWorks ends.

5.3 This clause continues after this agreement ends.

## 6. Security safeguards

6.1 OpenWorks establishes and maintains the security measures that section 19 of POPIA requires: appropriate, reasonable technical and organisational measures to prevent the loss of, damage to or unauthorised destruction of Practice Information, and unlawful access to or processing of it. It identifies reasonably foreseeable risks, keeps its safeguards up to date, and checks regularly that they work.

6.2 The measures in place when this version was written are:

- Location: the Server runs on a virtual server in South Africa, as its own instance of Steady with its own database.
- Encryption in transit: Steady is reached only over HTTPS.
- Backups: the Server's data is backed up every night. Each backup is encrypted before it is written, with a key whose private part is kept off the Server. Backups are kept in South Africa and deleted after 30 days.
- Staff sign-in: psychologists, the practice administrator and OpenWorks support sign in with a password, a code from an authenticator app, and a device they have linked with a code sent to their email. On phones the app locks with the phone's own screen lock, and sensitive actions, such as exports, password resets and reading the access log, ask staff to confirm it is them.
- Access control: the Server, not the app, decides what each account may see. Patients see only their own information. Psychologists see their own patients, and a patient a colleague has shared with them. The practice administrator sees patients' names and whether they are connected, never what they share.
- OpenWorks support: OpenWorks' support accounts in the app see the Practice's staff and the Server, and no Patient Information, not even names. Reports that staff send with the app's Feedback button reach OpenWorks with a blurred screenshot; staff should not type Patient Information into them.
- The access log: every time someone reads Patient Information through Steady, it is written to an access log before it is shown, and if it can't be written, nothing is shown. The master clinician and the practice administrator can read the log in the app.
- Root access: as the operator that runs the Server, OpenWorks can technically reach the Server itself, as any host can. OpenWorks limits that access to the people who maintain the Server, and uses it only to maintain, back up, restore, update and repair the Server and to carry out the Practice's instructions. It does not read Patient Information while doing so unless a task the Practice asked for can't be done otherwise. PocketBase's own administration dashboard is switched off.
- Signed updates: OpenWorks sets the Server up to install only releases of Steady that OpenWorks has signed.
- Notifications and email: push notifications say only that there is something new. Account emails are only about the person's own account. Neither carries clinical information.
- Testing: every change to Steady must pass automated security tests before it is released.

6.3 Whether the Server's disk is also encrypted at rest depends on the hosting provider. OpenWorks tells the Practice on request.

6.4 OpenWorks may change these measures to keep up with new risks and technology, as long as the protection they give is not reduced.

6.5 The Practice looks after its own side: who it gives accounts to, keeping staff devices locked and up to date, stopping the accounts of people who leave, and keeping files exported from Steady safe (clause 13).

## 7. Sub-operators

7.1 The Practice authorises OpenWorks to use these Sub-operators:

- Rackzar: the virtual server that hosts the Server, in South Africa.
- domains.co.za: the mail service that sends Steady's account emails (staff sign-in codes and account notices, and patients' password-reset codes and deletion confirmations), located in [To complete: country where the mail is kept]. These emails carry no clinical information.
- Apple: delivers push notifications to iPhones (Apple Push Notification service).
- Google: delivers push notifications to Android phones, where they are sent through Google's Firebase Cloud Messaging.
- GitHub: holds Steady's source code and builds, and distributes Steady's releases and Android app. It receives no Practice Information.

7.2 A push notification sent through Apple or Google carries no personal information beyond the phone's device token (a code that lets the service deliver to that phone) and the fact and time of the notification. Its text is fixed and says only that there is something new.

7.3 OpenWorks chooses Sub-operators whose written terms require them to keep the information they handle secure and confidential, and uses each only for its part of the Service.

7.4 OpenWorks tells the Practice in writing at least 30 days before it adds or replaces a Sub-operator, and offers a new version of this agreement with the updated list. If the Practice objects on reasonable grounds and the parties can't agree on a solution, the Practice may end this agreement before the change takes effect.

## 8. Personal information outside South Africa

8.1 OpenWorks keeps the Server and its backups in South Africa.

8.2 The only Practice Information that leaves South Africa is what push notifications need: a phone's device token, and when a notification is sent, which go to Apple or Google (clause 7.2). The Practice authorises this and tells patients about it in its consent statement.

8.3 OpenWorks does not transfer any other Practice Information outside South Africa without the Practice's prior written consent, and then only as section 72 of POPIA allows.

## 9. Security Compromises

9.1 OpenWorks notifies the Practice immediately, and in any case within 24 hours of becoming aware, when there are reasonable grounds to believe that a Security Compromise has happened. It notifies the Practice's Information Officer and the Practice's contact in the Schedule, by phone and by email.

9.2 The notice says, as far as is known at the time, and is updated as more becomes known:

- what happened, and when;
- when OpenWorks found out;
- what Practice Information is or may be affected, and roughly how many patients or staff;
- the likely consequences;
- what OpenWorks has done, and will do, to contain it and limit harm;
- what the Practice and the people affected can do to protect themselves;
- whether the identity of the unauthorised person is known; and
- who at OpenWorks to contact about it.

9.3 Under section 22 of POPIA it is the Practice that notifies the Information Regulator and the people affected. OpenWorks cooperates fully and promptly: it gives the Practice the information the Practice needs, helps prepare the notifications, and does not notify the Regulator or the people affected itself unless the Practice asks it to or the law requires it.

9.4 OpenWorks keeps a record of each Security Compromise, what it did about it, and why.

## 10. Breach plan

10.1 When OpenWorks suspects a Security Compromise, it follows this plan:

- Contain: stop the access, for example by locking accounts, signing everyone out, changing keys and passwords, or taking the Server offline.
- Preserve evidence: keep the access log, the server logs and an encrypted copy of the affected data.
- Notify: tell the Practice under clause 9.
- Assess: find out what happened, what information was affected and whose, and the risk to the people affected.
- Support: help the Practice with its notifications under clause 9.3.
- Fix and learn: close the gap, restore from a backup if needed, check that the fix works, and give the Practice a written report of what happened, what was affected and what was changed, as soon as the investigation allows.

## 11. Help with data subjects' requests

11.1 When a patient or a staff member asks the Practice to see, correct or delete their information, or objects to how it is processed, OpenWorks helps the Practice respond promptly with what the Practice can't do in the app itself, for example an extract of the access log.

11.2 If a data subject contacts OpenWorks directly, OpenWorks passes the request on to the Practice and does not answer it itself, except to say it has been passed on.

11.3 Steady itself helps with these requests: patients can ask in the app to delete their account, psychologists can export a patient's record, and the master clinician and the practice administrator can read the access log.

## 12. Deletion on request

12.1 OpenWorks deletes any Practice Information the Practice asks it to delete, and confirms in writing when it is done.

12.2 Deleted information is removed from the Server straight away, and from backups as they are deleted, within 30 days.

12.3 Before it asks for deletion, the Practice keeps what it is required to keep, such as clinical records. The Practice's record-keeping duties are its own.

## 13. Clinical records

13.1 Patient Information in Steady is the Practice's. It becomes part of the Practice's clinical record when a psychologist exports it from Steady into the Practice's own records, for example as a PDF report, a workbook or a summary for the clinician's own tools.

13.2 From then on, the exported copy is part of the Practice's clinical record and the Practice's alone. Its storage, security, retention and any further sharing, including with any tool a clinician uses, are the Practice's responsibility. OpenWorks does not process it, and OpenWorks' responsibility for it ends when it is exported.

13.3 The Practice and its clinicians are responsible for clinical decisions and for how they use what Steady shows. Steady is not monitored around the clock and is not an emergency service.

## 14. When this agreement ends

14.1 Before the end date, or within 30 days after it if the Practice asks, OpenWorks gives the Practice a complete copy of the Server's data (its database and files, including the access log), in a form another Steady server can restore, and helps move it if the Practice wants Steady hosted elsewhere. Steady is free software, so the Practice can keep using it with another host.

14.2 Then OpenWorks deletes all Practice Information from the Server and its other systems, lets the backups expire within 30 days, and confirms in writing when it is done. It keeps nothing unless a law requires it to, and then only what that law requires, kept confidential under clause 5.

## 15. Audits and information

15.1 On request, OpenWorks gives the Practice the information it reasonably needs to show that this agreement and POPIA are complied with, such as a description of the safeguards, the results of OpenWorks' security check of the Server, the current list of Sub-operators, and who at OpenWorks has access to the Server.

15.2 The Practice may audit OpenWorks' compliance with this agreement, itself or through an independent auditor bound by confidentiality, on 10 business days' written notice, and no more than once a year unless a Security Compromise has happened. Each party pays its own costs. No audit may give anyone access to other practices' information.

15.3 Steady's source code is public, so anyone can check how it handles information.

## 16. Information Officer

16.1 The Practice's Information Officer is the master clinician who signs this agreement, unless the Practice names someone else in the Schedule.

16.2 The Practice makes sure its Information Officer is properly appointed under POPIA and the Promotion of Access to Information Act 2 of 2000 and registered with the Information Regulator, and tells OpenWorks in writing when its Information Officer or their contact details change. The Practice can record a change by signing this agreement again in Steady with the new details.

16.3 OpenWorks sends notices under this agreement to the Practice's Information Officer and the Practice's contact in the Schedule.

## 17. Term and ending

17.1 This agreement starts when the Practice signs it, and lasts as long as OpenWorks processes Practice Information for the Practice.

17.2 Either party may end the Service, and with it this agreement, by giving the other 30 days' written notice.

17.3 Either party may end it immediately by written notice if the other materially breaches it and does not put the breach right within 14 days of being asked to in writing.

17.4 Clauses 5, 9, 12, 14, 18 and 21 continue after this agreement ends, for as long as they are relevant.

## 18. Liability

18.1 Each party is liable to the other for loss caused by its breach of this agreement, as South African law provides.

18.2 Nothing in this agreement limits or excludes liability for fraud, wilful misconduct or gross negligence, or any liability that the law does not allow to be limited or excluded.

## 19. New versions of this agreement

19.1 OpenWorks may offer a new version of this agreement, for example when a Sub-operator changes. It is shown to the master clinician in Steady and takes effect when the Practice signs it there. Until then, the version the Practice last signed applies.

19.2 Any other change to this agreement must be in writing and signed by both parties.

## 20. Signing electronically

20.1 The Practice signs this agreement in Steady. Its authorised representative confirms it is them (with their phone's screen lock or an authenticator code), types their full name as their signature, confirms they are authorised to sign for the Practice, and taps Sign.

20.2 The parties agree that this is an electronic signature for the purposes of section 13 of the Electronic Communications and Transactions Act 25 of 2002, with the same effect as a handwritten signature.

20.3 Steady keeps a record of each signature that can't be changed through the app: the version of this agreement, its full text and that text's SHA-256 fingerprint, the details in the Schedule, the signer's account, name and email, and the time, internet address and app used. That record is evidence of this agreement and its terms.

20.4 OpenWorks makes this agreement available in Steady and is bound by it when the Practice signs. Signed for OpenWorks by Tiaan van der Merwe, Director, Founder and Principal Engineer, who is authorised to do so.

20.5 The master clinician, the practice administrator and OpenWorks can open the signed agreement in Steady at any time and download it as a PDF.

## 21. General

21.1 South African law governs this agreement.

21.2 If this agreement conflicts with any other terms between the parties about Practice Information, this agreement applies.

21.3 If any part of this agreement is found to be invalid, the rest still applies.

21.4 Notices are given by email to the addresses in clause 1.1 and in the Schedule. A notice under clause 9 is also given by phone.

21.5 A delay or a concession by either party does not waive its rights.

## Schedule: the Practice's details

Recorded in Steady when the Practice signs, and printed with each signed copy:

- the Practice's legal name;
- its registration or practice number;
- its physical address;
- its contact email and phone number;
- its Information Officer's name, email and phone number (the master clinician, unless the Practice names someone else); and
- who signed for the Practice, with their account email, and when.

---

## Notes (not part of the agreement)

### How it is signed and kept

- The practice's master clinician sees the agreement the first time they open Steady after their
  server is updated, and again whenever its version changes. They fill in the practice's details,
  leave the Information Officer box ticked (or untick it and name someone else), type their full
  name, tick that they're authorised to sign for the practice, tap Sign, and confirm it's them
  (the phone's screen lock, or an authenticator code on the web). Other staff aren't asked.
- Each signature is a new row in `operator_agreements`: the version, the full text and its
  SHA-256, the details given, the signer's account, name and email at the time, the time, the
  internet address and the app. Nobody can change or delete a row through the API, superusers
  included, and the server refuses to change or delete one at all. Signing again (new details,
  such as a new Information Officer) adds a row; the newest counts.
- The master clinician, the practice admin and OpenWorks support open the signed copy under
  Settings > The practice > Operator agreement, and can download it as a PDF. It holds no patient
  information.
- `sudo ./accounts.sh check` says whether the current version is signed, `audit-server.sh` fails
  until it is, and the fleet view shows it for every server.

### Changing the text

1. Edit `server/pb_hooks/content/operator-agreement.md`.
2. Give it a new version: the `Version` line at the top of the text and `VERSION` in
   `server/pb_hooks/lib/operator.js`.
3. Set `TEXT_SHA256` in `lib/operator.js` to the new text's SHA-256 (the server tests print it),
   and copy the text into this file between the note at the top and these notes.

The server tests fail until all three agree, so a text that was signed can't change under the
same version. Each server's master clinician signs the new version the next time they open
Steady after the update.

### Blanks for OpenWorks to fill in before release

Left as `[To complete: ...]` in the text (`accounts.sh check` and `audit-server.sh` warn while any
are left):

- Where domains.co.za keeps the Steady mailbox's mail (clause 7.1): to check with domains.co.za.

Filled in on 3 November: the registration number (2024/733128/07), the address (24 Pelican Road, Port Elizabeth, 6070), the Information
Officer (Tiaan van der Merwe), the phone and WhatsApp number, and who signs for OpenWorks (Tiaan
van der Merwe, Director, Founder and Principal Engineer).

The live list of what a lawyer should confirm, across this agreement, the consent statement and
the privacy policy, is kept in the "Steady: for a lawyer to confirm" document; the points below
are this agreement's.

### Points for the attorney

- **Liability (clause 18)** is deliberately neutral: no cap, no exclusions, no indemnities.
  Decide what OpenWorks offers and whether it carries professional indemnity or cyber insurance.
- **Sub-operators (clause 7.3)**: Apple, Google, GitHub and the mail host contract on their
  own standard terms, which OpenWorks can't change. Check that clause 7.3 is enough for section
  21, and whether OpenWorks should remain responsible to the practice for its sub-operators.
- **Transfers abroad (clause 8)**: device tokens and the timing of notifications go to Apple and
  Google outside South Africa. Confirm which ground in section 72(1) the practice relies on (the
  patient's consent in the practice's consent statement, or that it is needed for the service
  the patient asked for), and whether a device token is personal information at all.
- **Information Officer (clause 16)**: under POPIA the Information Officer of a private body is
  its head (as PAIA defines it), or a person the head duly authorises. The master clinician is
  the default here because the owner asked for it; check the wording for a practice where the
  master clinician isn't the head (for example a partnership or a company), and whether the
  practice must also designate deputies.
- **Electronic signature (clause 20)**: the practice signs by typed name, a tick and "confirm it's
  you". Confirm that POPIA's "written contract" doesn't call for an advanced electronic signature
  under ECTA section 13(1), and that OpenWorks' side is properly executed by clause 20.4
  (acceptance by making it available) rather than a separate signature.
- **Breach notice (clause 9.1)**: section 21(2) says "immediately"; "within 24 hours" is the
  outside limit the owner chose. Check it doesn't read as permission to wait.
- **Term and notice (clause 17)**: the 30-day notice and the 14 days to put a breach right are
  placeholders.
- **New versions (clause 19.1)**: the app asks the master clinician to sign each new version
  before they can go on. Check that this is a fair way to agree changes, and what applies if
  a practice doesn't sign.
- **Security measures (clause 6.2)**: these are what Steady does now, from its documentation.
  Disk encryption at rest is not promised (clause 6.3): it depends on the hosting provider.
- **Fees and the service itself** aren't in this agreement (clause 3.4); they're in OpenWorks'
  quote or invoice. Check whether a separate service agreement is wanted.
