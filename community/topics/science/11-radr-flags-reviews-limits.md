# RADR: flags, reviews, the list and the limits

## What it is

How RADR's daily rating reaches you: as flags you can open and mark as reviewed, as a place in your patient list, as explanations behind every number, and in exports. It also sets out what RADR can't tell you. The method itself is in "RADR: how a day is rated".

## How it came about

In Steady 1.0, RADR showed its numbers and could rank a patient as high as an answer waiting for review. Steady 1.1.0 changed three things: every number now opens to show why it is what it is; each domain away from usual became a flag that can be marked as reviewed, so a change you have looked at stops lifting the same patient day after day; and RADR was placed below every answer waiting for review, in line with the evidence that asking does at least as well as passive data (Büscher et al. 2024).

## How it works

### The latest day

Steady looks at the last 7 days and takes the most recent rated day as the patient's **latest day**. It is refreshed when watch data arrives, when you switch a domain off or on, when a flag is marked as reviewed, and every night at 05:15 South African time. If the latest day is more than 3 days old, for example because the watch stopped syncing, RADR stops counting in your list.

### Flags

On the latest day, each counted domain at 1.5 or more is a flag, such as "Sleep away from usual since Tue 28 Oct". A flag belongs to its **run**: the unbroken stretch of days the domain has been away from usual. Days without data for that domain don't end a run unless more than 7 come in a row; a day with data that is back under 1.5 does end it. The flag keeps its identity for as long as the run lasts.

### Marking as reviewed

The patient's psychologist, or a colleague the patient is shared with, can mark a flag as reviewed, with an optional note (up to 500 characters). Steady records who and when and shows "Reviewed by [name], [date]" wherever the flag appears. The patient, the practice administrator and OpenWorks IT can't see reviews.

A review holds until something new appears: another domain moving away from usual, or this domain coming back to usual and then moving away again. A domain moving further from usual within the same run doesn't count as new.

A made-up example: a patient's sleep domain passes 1.5 on a Tuesday and stays there. You review it on Thursday. On Saturday their activity domain also passes 1.5: that is a new flag, and the patient moves up your list again. Sleep, still in the same run, stays reviewed.

### Your list

| What RADR shows on the latest day | Effect on your list |
|---|---|
| No domain away from usual, or the latest day more than 3 days old | None |
| Domains away, every flag reviewed | None; "RADR reviewed" shows on the row |
| Domains away, not all reviewed | Moves up by how many: 1, 2, or 3 and 4 alike |

RADR always ranks below any answer waiting for review (a questionnaire flag or band, or low mood in the check-ins), however recent. It is never shown in alarm colours, and nothing about it is sent as a notification. For patients marked "Stable, ease off", RADR flags aren't shown or counted. The whole order is in "How the patient list is ordered".

### Every number explained

Tap any number, day, domain or flag. Steady shows, in plain words, what was measured, this person's usual (the baseline median), "give or take" (the spread RADR divides by), the value then, how far it is from usual and why that measure counts, with the readings behind it. The explanation uses the same data and maths as the rating; tests check that both give the same numbers. Opening an explanation is written to the access log, like every read of patient data, and if the log can't be written nothing is shown.

### Switching a domain off

For one patient, their own psychologist can stop a domain counting, for example sleep for a shift worker, with a reason that shows wherever RADR does. The data is still collected and shown, just not counted in the watch index, the domains away or the list.

### Exports

PDF reports, Excel workbooks and the export for AI note-taking list the flags on the latest day and whether each was marked as reviewed, and state the method version (`radr-1`) and its settings, so a file read later says how its numbers were made.

### Demo patients

For training, OpenWorks IT can add three fictional demo patients (steady, gradual low mood, acute sleep disruption) to a psychologist's list, marked as made-up data wherever they appear. They are not a model of any illness and must never be mixed with real data in any analysis.

## Limits

**How the method behaves**

- **It measures change, not state.** A lasting change is gradually absorbed into the person's usual: once most of the 28 baseline days fall after a sudden change, about three weeks in, the scores drift back towards 0 even if nothing has improved. The questionnaires remain the measure of how unwell someone is.
- **Only change towards decline counts.** More activity, or less sleep with higher mood, adds little, so a shift towards hypomania shows only partly, through shorter sleep and a body-clock shift.
- **Weighting is a judgement.** All domains count equally, and within a domain the stronger measure wins. Other reasonable choices would give different numbers.
- **Concordance is weaker than it looks.** Neighbouring days share smoothed values and overlapping baselines, so 30 days hold far fewer than 30 independent observations; with 30 truly independent pairs, a correlation of about ±0.36 can arise by chance. Four lags are tested, and no confidence intervals are given.

**The data**

- **No heart rate variability.** The heart domain rests on resting heart rate alone.
- **Some brands may send nothing**, leaving RADR with check-ins only and no watch index.
- **Resting heart rate has two sources**: from sleep, and from the daytime when no sleep was recorded.
- **Naps count towards sleep**, and wear time isn't known.
- **A new watch, phone or time zone** can look like a change in the person.
- **Check-ins are coarse**: five points, with a floor of 0.35 so a habitually steady rater isn't over-scored.

**The evidence**

- The thresholds and floors are untested starting points.
- The research came from other people, devices and settings; most studies were small, short and single-centre. None studied a South African private practice with consumer watches.

## Open questions

These are open for discussion and, where agreed, for VR Clinical Psychology's sign-off: each setting in the method; whether naps should count; how to treat daytime resting heart rate; adding time awake at night to the sleep domain (Zhang et al. 2021 found it among the strongest sleep signals); counting the other direction for hypomanic shifts; showing a fixed "well" reference period beside the rolling usual; and what outcome RADR should be judged against, fixed before anyone looks at the results.

Replies on any of these, and on how RADR fits your reviews, are welcome.

## Where this lives

- `server/pb_hooks/lib/radr.js`: `flags` (runs and keys, `GAP_MAX` = 7), `level` (the 3-day limit and "reviewed") and `explain`
- `server/pb_hooks/lib/radr_data.js`: `current` (the latest day), `refreshLatest`, `markReviewed`, `reviews` and `exclusions`
- `server/pb_hooks/steady_research.pb.js`: the RADR, explanation and review routes
- `server/pb_hooks/steady_care.pb.js`: switching a domain off, and the nightly `steady_radr_latest` refresh
- `server/pb_hooks/lib/core.js`, `attention`: RADR's place below answers
- `server/pb_hooks/lib/records.js`, `patientRecord`: RADR in exports

## References

- Büscher R. et al. (2024). A systematic review on passive sensing for the prediction of suicidal thoughts and behaviors. *npj Mental Health Research* 3:42. https://doi.org/10.1038/s44184-024-00089-4
- Lim D. et al. (2024). Accurately predicting mood episodes in mood disorder patients using wearable sleep and circadian rhythm features. *npj Digital Medicine* 7. https://doi.org/10.1038/s41746-024-01333-z
- Zhang Y. et al. (2021). Relationship between major depression symptom severity and sleep collected using a wristband wearable device: multicenter longitudinal observational study. *JMIR mHealth and uHealth* 9(4):e24604. https://doi.org/10.2196/24604
