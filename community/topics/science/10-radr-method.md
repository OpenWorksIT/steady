# RADR: how a day is rated

## What it is

This is the `radr-1` method exactly as the code runs it. RADR rates each day by comparing every measure with the same person's own recent weeks, scoring how far it has moved in the direction the research links to decline, then grouping the scores into four watch domains and a separate check-in score. It is worked out again from the stored daily values whenever you open the RADR tab, an explanation or an export, so the same data always gives the same numbers. Only the latest day's result is kept on the patient's record, so your list can be ordered without working RADR out for everyone each time. Why it is built this way is in "RADR: what it is and the evidence behind it".

## How it came about

The structure follows the studies in that topic: combine domains, compare each person with themselves, keep self-report beside the watch. The numbers below (window lengths, floors, the 1.5 threshold, the cap of 4) were set by judgement for the first stage of use at VR Clinical Psychology. They are reasoned starting points to be tested, not validated cut-offs.

## How it works, step by step

**1. One value per day.** A day is the patient's local calendar day. From the watch: sleep length, the times they fell asleep and woke, steps and resting heart rate (see "Watch and phone data"). From the check-ins: that day's mean mood, anxiety, sleep rating and energy. Two values are derived:

- **Sleep midpoint**: halfway between falling asleep and waking (waking moved to the next day when it is earlier than falling asleep).
- **Sleep irregularity**: the standard deviation of the time they fell asleep plus the standard deviation of the time they woke, over the 7 nights ending on the day (sample standard deviation; at least 4 nights of each).

**2. Smoothing.** Every measure except irregularity is averaged over the 3 days ending on the day, and needs values on at least 2 of them. One odd night or a missed check-in is damped; a change that lasts shows within two or three days.

**3. The person's usual.** The baseline for a day is the same smoothed measure on each of the 28 days from 35 to 8 days before it. The 7 days just before are left out on purpose, so a change building over the past week isn't absorbed into the usual it is compared with. At least 14 of the 28 days need a value.

**4. Distance from usual.** A robust z-score: (today's value − the baseline median) ÷ the spread, where the spread is 1.4826 × the median absolute deviation, or the measure's minimum spread (its floor) if that is larger. The median and median absolute deviation resist a few unusual days in the baseline better than the mean and standard deviation do (Leys et al. 2013); the factor 1.4826 puts the spread on the scale of a standard deviation. The floor stops a very regular person's tiny changes from scoring as large.

**5. Direction and cap.** Only movement in the direction linked to decline counts, and each watch measure counts from 0 to at most 4.

| Measure | Counts when | Floor (minimum spread) |
|---|---|---|
| Sleep length | Shorter or longer than usual | 20 min |
| Sleep irregularity | More irregular than usual | 12 min |
| Sleep midpoint | Earlier or later than usual | 20 min |
| Steps | Fewer than usual | 800 steps |
| Resting heart rate | Higher than usual | 1.5 bpm |
| Heart rate variability (not collected) | Lower than usual | 3 ms |
| Mood, energy, sleep rating (check-ins) | Lower than usual | 0.35 points |
| Anxiety (check-ins) | Higher than usual | 0.35 points |

**6. Four domains**, each 0 to 4, taking the stronger of its measures so one clear change isn't diluted:

| Domain | Score |
|---|---|
| Sleep | The larger of sleep length and sleep irregularity |
| Body clock | Sleep midpoint (shown as "earlier" or "later") |
| Activity | Steps |
| Heart | Resting heart rate (the heart rate variability half never has data) |

A domain with no score that day is left out, not counted as 0. A domain you have switched off for this patient is also left out, though still shown.

**7. Watch index and domains away from usual.** The watch index is the mean of the domains that have a score, and needs at least 2; otherwise the day isn't rated. **Domains away from usual** is how many domains score 1.5 or more that day, 0 to 4. This count is what orders your list.

**8. Check-in score.** The four check-in measures go through steps 2 to 5 the same way. The check-in score is the mean of those available (at least 2 of the 4), capped at 4. It is shown beside the watch, never inside the watch index.

**9. Combined score.** The mean of the watch index and the check-in score, on days that have both. Equal weight, because neither source has been shown to beat the other.

**10. Concordance.** Over the period you are viewing (4 weeks, 8 weeks or 3 months in the RADR tab; up to a year in a report), Steady pairs each day's watch index with the check-in score on the same day and 1, 2 and 3 days later, and gives a Spearman rank correlation for each, with the number of pairs. It needs at least 10 pairs. A stronger correlation 1 to 3 days ahead would suggest the watch moves before the person reports a change; that is the main question RADR is there to answer.

Scores are kept to two decimal places, and each day records how many baseline days it had.

## A made-up example

A patient's smoothed sleep has been about 7 hours (420 minutes) for a month, varying little: median absolute deviation 15 minutes, so the spread is 22.2 minutes (above the 20-minute floor). Over the last three nights they slept 5 h 10, 5 h 00 and 5 h 20: a mean of 310 minutes, a z-score of −4.95. Shorter sleep counts, so the sleep domain is 4 (capped). Their steps have run at a median of 7,000 with a median absolute deviation of 400; 1.4826 × 400 is 593, below the 800 floor, so the spread is 800. A three-day mean of 5,600 gives −1.75, so activity is 1.75. Body clock and heart each come to 1.0.

The watch index is (4 + 1.75 + 1 + 1) ÷ 4 = 1.94. Two domains, sleep and activity, are away from usual. If their check-ins over the same days give a check-in score of 2.7, the combined score is 2.3.

## Where the numbers start

A day is rated once at least two domains have 14 baseline days. A patient who starts wearing a watch the day they connect is rated after about three weeks. Because connecting reads up to 30 days back, a patient whose phone already holds a month of data can be rated the same day.

## Limits

These are covered fully in "RADR: flags, reviews, the list and the limits". Most important here: every number in the tables above is a judgement awaiting test; RADR measures change, not state, so a lasting change is absorbed into the usual within about three weeks; and the heart domain has no heart rate variability.

Questions about any step, or proposals for different numbers, are welcome in the replies.

## Where this lives

- `server/pb_hooks/lib/radr.js`: the settings (`BASELINE_DAYS`, `BASELINE_GAP`, `BASELINE_MIN`, `SMOOTH`, `NOTABLE`, `CAP`, `FLOOR`) and `midpoint`, `variability`, `smoothed`, `compare`, `robustZ`, `dayRating`, `spearman`, `concordance` and `rate`
- `server/pb_hooks/lib/radr_data.js`, `load` (the daily values and check-in means) and `forPatient`
- `server/pb_hooks/steady_research.pb.js`, `/api/steady/patients/{id}/radr`
- `server/tests/radr.test.js`: checks that the method and its explanations give the same numbers

## References

- Leys C., Ley C., Klein O., Bernard P., Licata L. (2013). Detecting outliers: do not use standard deviation around the mean, use absolute deviation around the median. *Journal of Experimental Social Psychology* 49(4):764–766. https://doi.org/10.1016/j.jesp.2013.03.013
- Bernert R.A., Hom M.A., Iwata N.G., Joiner T.E. (2017). Objectively assessed sleep variability as an acute warning sign of suicidal ideation in a longitudinal evaluation of young adults at high suicide risk. *Journal of Clinical Psychiatry* 78(6):e678–e687. https://doi.org/10.4088/JCP.16m11193
- Lim D. et al. (2024). Accurately predicting mood episodes in mood disorder patients using wearable sleep and circadian rhythm features. *npj Digital Medicine* 7. https://doi.org/10.1038/s41746-024-01333-z
- Pedrelli P. et al. (2020). Monitoring changes in depression severity using wearable and mobile sensors. *Frontiers in Psychiatry* 11:584711. https://doi.org/10.3389/fpsyt.2020.584711
