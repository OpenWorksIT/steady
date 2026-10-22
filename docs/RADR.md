# RADR: Research Amon Dîn Rating

RADR is a **research view** in the psychologist's app (patient > RADR tab). It shows, day by
day, how far a patient's watch data and check-ins are from that person's own normal, grouped into
four domains, and whether the watch and the check-ins move together. It exists so the practice
can study, in ordinary care, what the research below reports, and use that to decide how Amon Dîn
should work.

**It is not a risk score, a prediction or a diagnosis**, it is not monitored around the clock,
and nothing is triggered by it. The code is `server/pb_hooks/lib/radr.js` (version `radr-1`).

## What the research says, in short

- **Single watch measures predict poorly.** In 267 Fitbit users, individual measures correlated
  only weakly with PHQ-9 (|ρ| 0.12 to 0.26), and models built from one category of measures did
  worse than models combining selected measures across categories (Rykov et al. 2021).
- **Combinations, compared with the person's own history, do better.** Mood-episode prediction
  from sleep and circadian features reached AUC 0.80 for depressive episodes when the models were
  personalised; daily shifts in the body clock were the strongest predictor, with delays before
  depressive episodes (Lim et al. 2024). Relapse detection in psychosis works by learning each
  patient's own stable period and flagging departures from it (e-Prevention; Zlatintsi et al.
  2024, Tsalkitzis et al.).
- **Sleep irregularity is the clearest watch-measured warning sign for suicidal ideation.**
  Night-to-night variability of falling asleep and waking predicted increases in suicidal
  ideation over 21 days, independent of depression (Bernert et al. 2017). Short and poor sleep
  predicted next-day suicidal ideation (Littlewood et al. 2019).
- **Heart rate variability carries signal.** With a Galaxy Watch Active2 (activity, sleep, heart
  rate, HRV) plus mood ratings, imminent suicide risk was identified with AUC 0.89; HRV was among
  the top predictors (Um et al. 2025).
- **But passive data has not yet beaten asking.** A systematic review found passive sensing
  generally gave lower performance than self-report, and three of four studies found no added
  value from it (Büscher et al. 2024). In 2,459 medical interns, mood-only models predicted
  depression and suicidal ideation best (Horwitz et al. 2022). In inpatients, wearable-only and
  clinical-only models were similar and combining them roughly doubled recall (Lee et al. 2026).

So RADR combines domains, compares each person with themselves, and keeps the check-ins beside the
watch rather than inside it, so the practice can see whether the watch adds anything.

## How RADR works

1. Each measure is averaged over 3 days and compared with the person's own **baseline**: the 28
   days ending a week before the day (so a change that is building doesn't hide in its own
   baseline). A day is rated once the baseline holds 14 days of data.
2. Distance from usual is a **robust z-score** (median and MAD, with a minimum spread per measure),
   counted only in the direction the research links to decline, and capped at 4.
3. Four **domains**, each 0 to 4:

   | Domain | Watch measures | Direction counted | Basis |
   |---|---|---|---|
   | Sleep | Sleep duration; SD of sleep onset + SD of waking over 7 nights | Duration either way; variability up | Bernert 2017, Littlewood 2019 |
   | Body clock | Sleep midpoint | Earlier or later | Lim 2024 |
   | Activity | Daily steps | Fewer | Rykov 2021, Lee 2026 |
   | Heart | Resting heart rate; HRV (RMSSD) when the watch provides it | Resting HR up, HRV down | Um 2025, Rykov 2021 |

4. **Watch index** = the mean of the domains (at least two). **Domains away from usual** = how many
   are at 1.5 or more on the same day.
5. **Check-in score**: lower mood and energy, more anxiety, worse sleep, scored the same way.
   **Combined** = the mean of the watch index and the check-in score.
6. **Concordance**: Spearman correlation between the watch index and the check-in score, with the
   watch 0 to 3 days ahead.

## Demo patients

`sudo ./accounts.sh demo-patients <psychologist email>` adds three **fictional** patients with eight
weeks of watch data, check-ins and weekly PHQ-9 and GAD-7 results (`--remove` takes them out). They
are shaped after the patterns above, not a validated model of any illness, and must never be mixed
into research results.

| Demo | Pattern | What RADR shows (latest day) |
|---|---|---|
| A · steady | Eight ordinary weeks | Watch index about 0.5, no domains away from usual, no relation to check-ins (ρ ≈ 0.06) |
| B · gradual low mood | Four stable weeks, then sleep later, longer and irregular, fewer steps, resting HR up, mood and energy down, PHQ-9 4 to 16 | Watch index about 2.2, three domains away from usual, ρ ≈ 0.84 |
| C · acute sleep disruption | Six stable weeks, then two weeks of short, erratic sleep, resting HR up, restless then flat activity, anxiety up, PHQ-9 5 to 16 with item 9 answered | Watch index about 3.8, all four domains away from usual, ρ ≈ 0.94 |

## Limits

- No study above used the same watches, measures or people as this practice; most were small,
  short and single-centre, and several had quality concerns.
- Health Connect daily summaries are coarse: no minute-level activity, no night-time heart rate
  profile, and HRV only if the watch app writes it.
- Watch wear and check-in gaps make every number less reliable; RADR shows how many days it had.
- The thresholds (14-day minimum, 1.5 for "away from usual", cap of 4) are starting points to be
  tested, not validated cut-offs.

## Sources

- Büscher R. et al. (2024). [A systematic review on passive sensing for the prediction of suicidal thoughts and behaviors](https://doi.org/10.1038/s44184-024-00089-4). *npj Mental Health Research* 3.
- Horwitz A.G. et al. (2022). [Using machine learning with intensive longitudinal data to predict depression and suicidal ideation among medical interns over time](https://doi.org/10.1017/S0033291722003014). *Psychological Medicine*.
- Um J. et al. (2025). [Machine learning models to identify individuals with imminent suicide risk using a wearable device: a pilot study](https://doi.org/10.30773/pi.2024.0257). *Psychiatry Investigation* 22(2):156-166.
- Lee Y. et al. (2026). [Use of ecological momentary assessment via wearable devices for detecting acute suicide risk in psychiatric inpatients](https://www.frontiersin.org/journals/psychiatry/articles/10.3389/fpsyt.2026.1849140/full). *Frontiers in Psychiatry* 17.
- Haines-Delmont A. et al. (2020). [Testing suicide risk prediction algorithms using phone measurements with patients in acute mental health settings](https://mhealth.jmir.org/2020/6/e15901). *JMIR mHealth and uHealth* 8(6):e15901.
- Bernert R.A. et al. (2017). [Objectively assessed sleep variability as an acute warning sign of suicidal ideation](https://www.psychiatrist.com/jcp/sleep-variability-and-acute-suicide-risk/). *Journal of Clinical Psychiatry* 78(6):e678-e687.
- Littlewood D.L. et al. (2019). [Short sleep duration and poor sleep quality predict next-day suicidal ideation](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC6331731/). *Psychological Medicine* 49(3):403-411.
- Lim D. et al. (2024). [Accurately predicting mood episodes in mood disorder patients using wearable sleep and circadian rhythm features](https://doi.org/10.1038/s41746-024-01333-z). *npj Digital Medicine* 7.
- Rykov Y. et al. (2021). [Digital biomarkers for depression screening with wearable devices](https://mhealth.jmir.org/2021/10/e24872). *JMIR mHealth and uHealth* 9(10):e24872.
- Pedrelli P. et al. (2020). [Monitoring changes in depression severity using wearable and mobile sensors](https://frontiersin.org/articles/10.3389/fpsyt.2020.584711/full). *Frontiers in Psychiatry* 11.
- Zlatintsi A. et al. (2024). [Person identification and relapse detection from continuous recordings of biosignals challenge](https://doaj.org/article/ac7f0b06f1a045adb26b40e7f8ddba4a). *IEEE Open Journal of Signal Processing* 5:641-651.
- Tsalkitzis N. et al. [Uncertainty-driven anomaly detection for psychotic relapse using smartwatches](https://arxiv.org/abs/2605.13816). arXiv 2605.13816.
- Lyall L.M. et al. (2018). [Association of disrupted circadian rhythmicity with mood disorders, subjective wellbeing, and cognitive function](https://pubmed.ncbi.nlm.nih.gov/29776774/). *The Lancet Psychiatry* 5(6):507-514.
