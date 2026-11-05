# Watch and phone data

## What it is

Patients can choose to share a daily summary of what their watch, or phone, records about heart rate, sleep, steps and blood oxygen. It is optional and off until the patient turns it on. Steady never talks to the watch: it reads what the watch's own app has written to the phone's shared health store (Health Connect on Android, Apple Health on iPhone), reduces each day to a summary on the phone, and uploads only that summary.

You see it against the patient's own usual range. No alert is raised from it. It feeds RADR, which orders your list (see the RADR topics).

## How it came about

The watch data started as a baseline for Amon Dîn, the wider project of which Steady is the first stage: collecting the same measures from day one so the practice has real data to judge them by. Three decisions shaped it.

- **Summaries, not raw data.** Only daily totals and averages leave the phone, which keeps what the practice holds to what it uses.
- **Each person against themselves.** Single watch measures relate only weakly to depression across people (in 267 Fitbit wearers, correlations with PHQ-9 were between 0.12 and 0.26; Rykov et al. 2021), and normal resting heart rate or sleep varies widely between people. So Steady shows each value against that patient's own recent range, not a population norm.
- **One method for every brand.** Watches estimate things like resting heart rate differently. Steady works out resting heart rate itself, the same way for every brand, so values compare over time even if the patient changes watch.

## How it works

### Consent

The patient reads what is shared and how it is used, and ticks to agree ("watch consent", version `wearable-2`). It says the data may be added to their clinical record and that it doesn't raise alarms. The time and version are stored. The patient can stop in Settings at any time: uploads stop, and what was already shared stays in the record.

### What is read, and the daily summary

Steady asks the health store for heart rate, steps, blood oxygen, and sleep sessions and stages. It does **not** read heart rate variability: working it out needs the time between individual heartbeats, which the shared stores don't pass on from most watches.

| Value | How the phone works it out |
|---|---|
| Lowest, average and highest heart rate | From all readings in the calendar day |
| Resting heart rate (`rhr-v1`) | The lowest average over any 30-minute stretch of that night's sleep, needing at least 3 readings spanning 10 minutes or more. With no sleep recorded, the lowest such stretch in the day, marked "measured awake" |
| Sleep | Sleep that **ended** on the day, naps included, so Monday night belongs to Tuesday. Total time asleep from the watch's stages where it records them, otherwise session length minus time awake |
| Fell asleep, woke up | The start and end of the day's longest sleep, in minutes from midnight (before midnight is negative) |
| Sleep stages, time awake | Light, deep, REM and awake minutes, if the watch records them |
| Steps | The day's total, which the health store de-duplicates across phone and watch. A day of 0 steps is treated as no data |
| Blood oxygen | Average and lowest for the day, if the watch measures it |

The server rejects values outside plausible ranges (for example resting heart rate outside 25 to 150 bpm, or sleep over 24 hours) rather than storing them, and rounds to one decimal place.

### When it syncs

On connecting, up to 30 days back. After that, each time the app opens, when the patient taps the breathing circle in the calm start, and when they tap "Sync now". Each sync re-reads from two days before the newest day that had data, so readings that reach the health store late are still picked up. Readings wait on the watch and phone until then, so nothing is lost if the app isn't opened for a while.

### What you see

- **Your list**: "N of 14 days", the number of the last 14 days with any watch data.
- **The patient's overview**: "Watch · last 7 days", each measure with its usual range shaded.
- **The Wearable tab**: resting heart rate, heart rate (lowest to highest, with the average), sleep, steps, blood oxygen and time fallen asleep, by day, week, month, six months or year. Longer views average the days that have data into weekly or monthly points.
- **A day's detail**: every value for that day with its usual range.
- **A lapsed permission**: if the phone stops letting Steady read the data (often after an update), the patient's page says so and lets you send a reminder; the patient's app asks them to allow it again.

**The usual range** for a day is the 10th to 90th percentile of that patient's own values over the 28 days before it, the day itself excluded. It appears once there are 7 days of readings, for resting heart rate, average heart rate, sleep, the time fallen asleep, steps and blood oxygen. It is shown, never alerted on. A made-up example: a patient whose sleep has sat between 6 h 40 and 7 h 30 for a month, and who then sleeps 5 h a night for a week, will show a week of bars well below the shaded band.

## What Steady deliberately doesn't use

**Sleep stages** are stored and shown in a day's detail but not charted or used in RADR. Even in the sleep laboratory, sleep changes in depression are not specific to it (Baglioni et al. 2016); consumer devices tell stages apart poorly against polysomnography (κ about 0.20 to 0.46; Schyvens et al. 2024); and in 368 people with depression wearing Fitbits, REM and deep sleep percentages were not related to depression severity, while time awake during the night was (Zhang et al. 2021).

**Heart rate variability** isn't collected, as above. RMSSD, the measure most linked to mood in the research, needs beat-to-beat intervals (Shaffer and Ginsberg 2017).

## Limits

- **Coverage depends on the brand.** Steady can only read what the watch's app shares with the phone's health store. Some brands share little or nothing; check with a patient's own phone that data arrives.
- **Wear time isn't known.** A day the watch sits on the charger still has phone steps, which looks like low activity.
- **Two kinds of resting heart rate share one series**: from sleep, and "measured awake" when no sleep was recorded. The second is usually higher.
- **Naps count towards sleep**, so a long afternoon nap raises the day's total.
- **A new watch, phone or time zone** can look like a change in the person.
- **The usual range follows the person**, so a change that lasts a month becomes the new usual.

Experience with particular watches, and with how patients take to sharing, is welcome in the replies.

## Where this lives

- `app/lib/wearable/summary.dart`: `summariseDay`, `restingHeartRate` (`rhr-v1`) and `sleepSessions`
- `app/lib/wearable/health_source_native.dart` (what is read) and `app/lib/wearable/wearable_sync.dart`, `WearableSync` (when, and how far back)
- `server/pb_hooks/lib/wearable.js`: `METRICS` (allowed values and ranges), `cleanDay` and `baselines` (the usual range)
- `server/pb_hooks/steady.pb.js`: `/api/steady/biometrics` (upload, and your view)
- `app/lib/ui/patient/watch_screens.dart`, `ConnectWatchScreen` (the consent), and `app/lib/ui/wearable/` (the charts)

## References

- Rykov Y. et al. (2021). Digital biomarkers for depression screening with wearable devices: cross-sectional study with machine learning modeling. *JMIR mHealth and uHealth* 9(10):e24872. https://doi.org/10.2196/24872
- Baglioni C. et al. (2016). Sleep and mental disorders: a meta-analysis of polysomnographic research. *Psychological Bulletin* 142. https://doi.org/10.1037/bul0000053
- Schyvens A.M. et al. (2024). Accuracy of Fitbit Charge 4, Garmin Vivosmart 4, and WHOOP versus polysomnography: systematic review. *JMIR mHealth and uHealth* 12:e52192. https://doi.org/10.2196/52192
- Zhang Y. et al. (2021). Relationship between major depression symptom severity and sleep collected using a wristband wearable device: multicenter longitudinal observational study. *JMIR mHealth and uHealth* 9(4):e24604. https://doi.org/10.2196/24604
- Shaffer F., Ginsberg J.P. (2017). An overview of heart rate variability metrics and norms. *Frontiers in Public Health* 5:258. https://doi.org/10.3389/fpubh.2017.00258
