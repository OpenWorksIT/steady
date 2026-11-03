# The daily check-in

## What it is

Four ratings from 1 to 5 and, if the patient wants, a few words. It is the one thing Steady asks of every patient every day, and the main way they tell you how they are between sessions.

| Rating | The question, as the patient sees it | 1 means | 5 means | Better is |
|---|---|---|---|---|
| Mood | How is your mood right now? | Very low | Very good | Higher |
| Anxiety | How anxious or tense do you feel? | Not at all | Extremely | Lower |
| Sleep | How did you sleep last night? | Very badly | Very well | Higher |
| Energy | How is your energy today? | Exhausted | Full of energy | Higher |

Each rating is a row of five numbered buttons with the two anchor words under the ends. Below them is "In a few words, how are you feeling?", optional, up to 1,000 characters. All four ratings must be answered before the check-in can be sent. The phone's keyboard is told not to learn from what is typed.

## How it came about

When Steady was started in October 2026, VR Clinical Psychology's brief was a patient opening the app, rating how they feel on a few 1 to 5 scales and writing a few words. Steady kept it to that on purpose.

Three lines of evidence sit behind the choice. None of them validates these four particular items.

- **Asking in the moment is more accurate than asking later.** Recall over a fortnight leans on the best and worst days and on mood at the time of asking; short, repeated ratings in daily life (ecological momentary assessment) reduce that bias (Shiffman et al. 2008).
- **Routine measurement with feedback helps therapy a little.** A multilevel meta-analysis of 58 studies and 21,699 patients found progress feedback gave a small improvement in symptoms (d = 0.15) and less drop-out (de Jong et al. 2021).
- **Short is kept up.** In an experience-sampling experiment, longer questionnaires raised perceived burden and lowered the quantity and quality of data, while how often people were asked mattered less (Eisele et al. 2022). In 2,459 medical interns, a single daily mood rating (1 to 10) predicted later depression and suicidal ideation as well as, or better than, models that added wearable data (Horwitz et al. 2023).

The four domains are core between-session concerns in general psychology practice, and each self-report sits beside a watch measure for patients who share one: the sleep rating beside measured sleep, energy beside activity. RADR uses that pairing.

## How it works

**When patients see it.** Each time the app opens, or after five minutes away, the calm start offers the check-in if there hasn't been one that calendar day. It can be skipped. On the home screen the card reads "Four quick questions and a few words. About a minute." After checking in, the patient can check in again at any time.

**Days and time zones.** Each check-in is stored with its time. A day is the patient's local calendar day, using the time zone their phone reports (South African time if none).

**More than one a day.** Allowed. Charts and RADR use the mean of each rating for the day. The low-mood flag counts individual check-ins, not days.

A made-up example: a patient checks in at 07:00 with mood 2 and at 21:00 with mood 4. The charts show a mood of 3.0 for that day; the low-mood rule sees two separate check-ins.

**What you see.** In your patient list: the time and mood of the latest check-in and a 14-day sparkline of daily mean mood. On the patient's page: a "Last 14 days" chart of daily mean mood and anxiety on one 1 to 5 axis, and each check-in with its four numbers and words. Each check-in also adds an item to your Alerts list ("[name] checked in", with mood and anxiety) and sends a push that says only "New notification".

**What the patient sees.** Their own check-ins over two weeks, a month or three months, as daily means, and each check-in card. No flags and no scores.

**What Steady does with the numbers.** Two things, and nothing else:

1. **The low-mood flag**: raised when the patient's last three check-ins all have a mood of 2 or lower. See "Review flags, item 9 and notifications".
2. **RADR's check-in score**: for patients who share watch data, how far mood, anxiety, sleep and energy are from that person's own usual. See the RADR topics.

The free text is not analysed, searched for words or scored. Only the people who can see the patient's record read it.

## Limits

- **Not a validated scale.** The four items have no published reliability, validity or norms. Read them as the patient's own report, and best as change within one person.
- **Single items are coarse.** Five points bunch at the ends, and one step can be noise. For a patient who nearly always answers 3, a single 2 looks like a large change against their own usual; RADR puts a floor under this.
- **Anxiety runs the other way.** For mood, sleep and energy, higher is better; for anxiety, higher is worse. Patients can mix this up, and so can a quick glance at the chart, where mood and anxiety share an axis.
- **The time frames differ.** Mood and anxiety are "right now", sleep is "last night", energy is "today". The time of day a patient checks in shapes the answer, and Steady doesn't adjust for it.
- **Missing days stay missing.** Nothing is filled in. A patient who checks in only on good days, or only on bad ones, will look that way.
- **The words may hold a disclosure of risk.** Steady doesn't detect it, and the app tells patients it isn't monitored around the clock. Decide, with your practice, how often you read them.

Questions, disagreements and better wording are welcome in the replies.

## Where this lives

- `app/lib/ui/patient/checkin_screen.dart`, `CheckinForm`: the questions and anchors
- `server/pb_hooks/lib/core.js`, `validateCheckin` (whole numbers 1 to 5, a note of up to 1,000 characters) and `dailySeries` (daily means)
- `server/pb_hooks/steady.pb.js`, the `checkins` record hooks: saving, and the notification to the psychologist
- `app/lib/ui/patient/daily_flow.dart` (when the check-in is offered) and `app/lib/ui/patient/history_screen.dart` (the patient's own view)

## References

- Shiffman S., Stone A.A., Hufford M.R. (2008). Ecological momentary assessment. *Annual Review of Clinical Psychology* 4:1–32. https://doi.org/10.1146/annurev.clinpsy.3.022806.091415
- de Jong K. et al. (2021). Using progress feedback to improve outcomes and reduce drop-out, treatment duration, and deterioration: a multilevel meta-analysis. *Clinical Psychology Review* 85:102002. https://doi.org/10.1016/j.cpr.2021.102002
- Eisele G. et al. (2022). The effects of sampling frequency and questionnaire length on perceived burden, compliance, and careless responding in experience sampling data in a student population. *Assessment* 29(2):136–151. https://doi.org/10.1177/1073191120957102
- Horwitz A.G. et al. (2023). Using machine learning with intensive longitudinal data to predict depression and suicidal ideation among medical interns over time. *Psychological Medicine* 53(12):5778–5785. https://doi.org/10.1017/S0033291722003014
