# How the patient list is ordered, and "Stable, ease off"

## What it is

Your patient list is ordered so that the patients with something waiting for you come first. It is an ordering of data, not a triage decision and not an alert: Steady doesn't decide who is at risk, it decides who goes higher on a screen. Tap the flags on any row to see, in plain words, why that patient is where they are.

This topic also covers the 14-day view on each patient's page, and the three places a patient can be in your work: seeing them, "Stable, ease off", and archived.

## How it came about

Steady's screens for psychologists follow a "deeper, not broader" rule: few things on the home screen, and the detail one tap down. So rather than a dashboard of numbers, the list itself answers "who should I look at first?". Routine outcome monitoring helps most when results reach the clinician in time to act, especially for patients who are not on track (de Jong et al. 2021), so the list puts unreviewed results first. What the patient told you directly comes before what Steady infers from watch data, because passive data has not yet been shown to beat asking (Büscher et al. 2024). "Stable, ease off" came from the opposite need: a way to stop a patient who is doing well from being highlighted, without losing their record.

## How it works

### The order

Each patient gets a rank from the flags in "Review flags, item 9 and notifications" and the RADR level in "RADR: flags, reviews, the list and the limits". Highest first:

| Rank | What puts the patient there |
|---|---|
| 6 | An answer not yet reviewed, red: PHQ-9 item 9, or a red band such as PHQ-9 15 or more, GAD-7 15 or more, WHO-5 28 or lower |
| 5 | An answer not yet reviewed, amber: an amber band, or low mood in the last 3 check-ins |
| 4 | An answer not yet reviewed with info severity (only from questionnaires a practice defines that way) |
| 3 | RADR: 3 or 4 domains away from usual, not all reviewed |
| 2 | RADR: 2 domains away, not all reviewed |
| 1 | RADR: 1 domain away, not all reviewed; or no check-in for 3 days or more, or none yet |
| 0 | Nothing waiting |
| Bottom | Marked "Stable, ease off" |

Within a rank, the most recent comes first (when the answer arrived, or RADR's latest day), then names in alphabetical order. A reviewed flag no longer counts. Questionnaire flags count for 14 days from completion; RADR counts only while its latest day is no more than 3 days old.

So RADR never comes before an answer waiting for review, however recent the RADR change. And a patient who has simply gone quiet ranks low: "No check-in for N days" sits level with a single RADR domain, below everything else.

### What a row shows

The patient's name, the time and mood of their latest check-in, the latest note on their record, "Shared by [name]" for a colleague's patient, "N of 14 days" of watch data, and a 14-day sparkline of daily mean mood. Under it: up to three unreviewed flags in their colours, "RADR: N of 4 away from usual" (never in alarm colours) or "RADR reviewed", "Watch permissions lapsed" if the phone stopped sharing, and how many flags are reviewed.

### The 14-day view

On a patient's page, below the flags: a "Last 14 days" chart of daily mean mood and anxiety on one 1 to 5 axis; "Watch · last 7 days" with the usual range shaded; everything sent and its results; and each check-in from the last 14 days. Fourteen days matches the two-week window of the PHQ-9, GAD-7 and WHO-5, so a questionnaire result and the daily ratings behind it can be read on one screen.

### Seeing them, stable, archived

Set in the patient's settings, by their own psychologist:

| Status | In your list | Highlighting | Notifications | Records |
|---|---|---|---|---|
| Seeing them (default) | In the usual order | Flags in colour, RADR shown | As usual | Kept |
| Stable, ease off | At the bottom, marked "Stable" | Flags listed without colour; RADR flags not shown or counted | As usual: check-ins still push | Kept; flags still recorded |
| Archive | Off your list (and off colleagues' shared lists) | None | Check-ins no longer push but still appear in Alerts; completed questionnaires and sent exercises still push | Kept; the account still works |

Archived patients are under Settings > Archived patients, where you can bring them back.

### Shared patients

A colleague's patient shared with you appears in your list, ordered the same way, marked "Shared by [name]". You can read everything and review RADR flags, but only their own psychologist can mark answer flags as reviewed or change their status.

## Limits

- **One queue for different things.** A red questionnaire flag and a run of low check-ins are different clinical signals; the list orders them, it doesn't weigh them for you.
- **Recency breaks ties**, so an older, unreviewed red flag can sit below a newer one.
- **Unreviewed answers age out** after 14 days and stop ordering the list, though the result keeps its flag.
- **Silence ranks low.** A patient who stops checking in rises only to rank 1, and only after 3 days.
- **Three and four RADR domains rank alike.**
- **"Stable, ease off" hides colour, not data.** A stable patient's new red flag doesn't lift them; open their page to see it. Use it with that in mind.
- **The rule is the same for every patient**: there is no per-patient weighting.

Suggestions for the order, and experiences of using "Stable, ease off", are welcome in the replies.

## Where this lives

- `server/pb_hooks/lib/core.js`: `attention` (the ranks and the plain-words reason), `sortByAttention`, `reviewFlags`
- `server/pb_hooks/lib/server.js`: `summaryOf` and `patientSummaries` (what each row holds)
- `server/pb_hooks/steady.pb.js`: `/api/steady/overview` (the list, own and shared patients)
- `server/pb_hooks/steady_care.pb.js`: `/api/steady/patients/{id}/care` (seeing them, stable, archived)
- `app/lib/ui/clinician/patients_screen.dart` (the rows) and `app/lib/ui/clinician/patient_detail_screen.dart` (the 14-day view)

## References

- de Jong K. et al. (2021). Using progress feedback to improve outcomes and reduce drop-out, treatment duration, and deterioration: a multilevel meta-analysis. *Clinical Psychology Review* 85:102002. https://doi.org/10.1016/j.cpr.2021.102002
- Büscher R. et al. (2024). A systematic review on passive sensing for the prediction of suicidal thoughts and behaviors. *npj Mental Health Research* 3:42. https://doi.org/10.1038/s44184-024-00089-4
