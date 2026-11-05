# Review flags, item 9 and notifications

## What they are

A flag is a short label Steady puts on a patient for you to look at, such as "PHQ-9: Item 9 endorsed: review" or "Low mood in the last 3 check-ins". Flags support your review. They are not a risk score, Steady takes no action on them, and nobody watches them out of hours.

Notifications are how you hear that something new has arrived: an item in your Alerts list, and a push to your phone that says only "New notification".

## How it came about

The flags were chosen with VR Clinical Psychology to surface what a patient has told you directly that would usually change what you do next: an answer about thoughts of death or self-harm, a score in a higher band, a run of low mood, or silence. Anything inferred from watch data is kept apart, in RADR, and always ranks below these.

PHQ-9 item 9 gets the most care because the evidence on it cuts both ways. Endorsing it is linked to a real rise in later suicide attempts, yet most people who endorse it never attempt, and it is positive for far more people than a structured suicide assessment is (Simon et al. 2013; Na et al. 2018; the figures are in the PHQ-9 topic). So Steady treats any endorsement as a prompt for your assessment, never as a level of risk.

## The flags

| Flag | Raised when | Severity | Counts for | Can be marked reviewed |
|---|---|---|---|---|
| Item flag | An answer meets an item rule in the questionnaire. Built in: PHQ-9 item 9 above "Not at all" | As defined (item 9: alert, red) | 14 days from completion | Yes |
| Band | The total falls in a band defined as warn (amber) or alert (red) | The band's | 14 days from completion | Yes |
| Low mood | The last three check-ins all have mood 2 or lower | Warn (amber) | Until a check-in breaks the run | Yes |
| No check-in for N days | The latest check-in was 3 or more full days ago | Info | Until the next check-in | No |
| No check-ins yet | The patient has never checked in | Info | Until the first | No |
| N waiting | Activities you sent are waiting and available | None | While they wait | No |

The built-in bands that flag are PHQ-9 10 to 14 (amber) and 15 to 27 (red); GAD-7 10 to 14 (amber) and 15 to 21 (red); PCL-5 31 to 80 (amber); WHO-5 29 to 50 (amber) and 0 to 28 (red). Mild and minimal bands don't flag. A patient's flags are listed most serious first, then most recent.

**The 14 days.** A questionnaire's flags count for 14 days from completion. After that they leave the flags and the order of your list, whether reviewed or not; the result keeps its band and flag, and exports show them.

**Low mood, exactly.** Steady looks at the patient's last three check-ins from the past 15 days, whatever days they fall on, so three low check-ins in one afternoon raise it. The flag belongs to the newest of the three. A review therefore holds until the next check-in: if that one has mood 3 or more, the run ends and the flag goes; if it is 2 or lower, the run continues and the flag returns, unreviewed.

A made-up example: mood 2 on Monday, 1 on Tuesday, 2 on Wednesday raises the flag. You mark it reviewed on Wednesday afternoon. Mood 2 on Thursday raises it again (Tuesday, Wednesday, Thursday). Mood 4 on Friday ends it.

## Marking a flag as reviewed

Tap the flag on the patient's page and mark it, with a note if you like (up to 500 characters). Steady records who and when, keeps the flag visible as reviewed, and stops it moving the patient up your list. A note is also added to the patient's notes as "Reviewed [flag]: [note]". Only the patient's own psychologist can mark these flags; a colleague the patient is shared with sees them but can't mark them. Exports list each flag with whether, by whom and when it was reviewed.

## Item 9 in Steady

- Any answer above "Not at all" raises "Item 9 endorsed: review", red, and puts the patient at the top of your list (unless you have marked them "Stable, ease off").
- The patient never sees their score, band or flag: the server withholds them.
- Nothing else happens. There is no special push, no escalation, no message outside working hours, no text or email.
- The patient's home screen, check-in, questionnaires, exercises, history and lock screen carry the crisis numbers: the SADAG Suicide Crisis Line (0800 567 567, 24 hours, free) and 112 from a mobile, always first, then any lines the practice adds, under "This app isn't monitored around the clock. If you need help now, call one of these numbers."
- Each practice decides whether PHQ-9 (with item 9) or PHQ-8 is sent between sessions, and how results that arrive outside working hours are handled. Steady can't make that decision for you.

## Notifications

| What happened | In your Alerts list | Push |
|---|---|---|
| A check-in | "[name] checked in", with mood and anxiety, plus "low mood in the last 3 check-ins" when the last three were all 2 or lower. Amber for that run, info when mood is 1 | Yes, except for archived patients |
| A questionnaire completed | "[name] completed PHQ-9", with score, band and any flag. Severity is the highest of the band and its flags | Yes |
| An exercise you sent, finished | "Exercise finished in N min" | Yes |
| An exercise the patient started themselves | "Started by the patient" | No |

Patients are notified when you send them something ("From your psychologist") and at 07:00 South African time when a repeating activity becomes available ("Ready for today").

Every push, on every phone, is titled "Steady" and says only "New notification": no name, score, words, or even what kind of thing is new. It goes through Apple or Google; the app fetches the detail over its own connection when you open it. The web app has no pushes. There are no quiet hours: a push arrives when the event happens, day or night, and your phone's own settings decide whether it makes a sound. In the Alerts list, an unread item has a dot in its severity's colour; red items carry "Review" and amber ones "Note". Items in the Alerts list are deleted after 90 days; the check-ins and results themselves stay.

## Limits

- **Flags are rules, not judgement.** Band flags follow each instrument's published cut-points (for the PHQ-9, Kroenke et al. 2001); the low-mood rule (three at 2 or lower) is a practice rule with no published basis.
- **Item 9 is over-inclusive and narrow.** It doesn't separate passive thoughts from intent, and a "Not at all" doesn't rule risk out.
- **Unreviewed flags age out** of your list after 14 days.
- **Silence ranks low.** "No check-in" appears only after 3 days and sits below answers and RADR.
- **Pushes carry nothing**, so you can't triage from the lock screen, and Apple and Google can delay or drop them.
- **Out of hours, nothing happens** until someone opens the app.

Replies on any of these rules are welcome, particularly the low-mood rule and the 14-day window.

## Where this lives

- `server/pb_hooks/lib/core.js`, `reviewFlags` (which flags, their severity and keys) and `attention` (their effect on the list)
- `server/pb_hooks/lib/server.js`, `summaryOf`, `notify` and `push`
- `server/pb_hooks/steady.pb.js`: the `checkins` record hooks, `/api/steady/assignments/{id}/complete`, and `/api/steady/config` (crisis lines)
- `server/pb_hooks/steady_care.pb.js`, `/api/steady/patients/{id}/flags/review`
- `server/pb_hooks/steady_privacy.pb.js`: scores, bands and flags withheld from patients
- `pusher/`: the relay that sends "New notification"

## References

- Simon G.E. et al. (2013). Does response on the PHQ-9 Depression Questionnaire predict subsequent suicide attempt or suicide death? *Psychiatric Services* 64. https://doi.org/10.1176/appi.ps.201200587
- Na P.J. et al. (2018). The PHQ-9 Item 9 based screening for suicide risk: a validation study of the Patient Health Questionnaire (PHQ)-9 Item 9 with the Columbia Suicide Severity Rating Scale (C-SSRS). *Journal of Affective Disorders* 232:34–40. https://doi.org/10.1016/j.jad.2018.02.045
- Kroenke K., Spitzer R.L., Williams J.B.W. (2001). The PHQ-9: validity of a brief depression severity measure. *Journal of General Internal Medicine* 16(9):606–613. https://doi.org/10.1046/j.1525-1497.2001.016009606.x
