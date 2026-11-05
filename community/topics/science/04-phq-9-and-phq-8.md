# PHQ-9 (and PHQ-8)

## What it is

The Patient Health Questionnaire-9 asks how often, over the last two weeks, the patient has been bothered by each of the nine DSM-IV criteria for major depression. It is Steady's built-in depression measure (`phq9`), described in the app as "Depression symptoms, 9 items, about 3 minutes". The PHQ-8 is the same questionnaire without item 9; it isn't built in, but can be imported.

## How it came about

The PHQ-9 was one of the four instruments VR Clinical Psychology asked for from the start. It is short, free to use, widely validated, and gives a severity score that can be repeated over time. Kroenke, Spitzer and Williams (2001) validated it in about 6,000 primary care and obstetrics-gynaecology patients, 580 of whom were re-interviewed by a mental health professional. A score of 10 or more had a sensitivity and specificity of 88% for major depression, and they proposed 5, 10, 15 and 20 as the thresholds for mild, moderate, moderately severe and severe depression. Steady's bands are those thresholds.

The larger evidence since then is consistent. An individual participant data meta-analysis found, against semi-structured interviews (29 studies, 6,725 participants), a sensitivity of 0.88 and specificity of 0.85 at a cut-off of 10 (Levis et al. 2019).

## How it works in Steady

**Instructions**: "Over the last 2 weeks, how often have you been bothered by any of the following problems?"

**Answers** for every item: Not at all (0), Several days (1), More than half the days (2), Nearly every day (3). All nine items are required.

| Item | Text |
|---|---|
| 1 | Little interest or pleasure in doing things |
| 2 | Feeling down, depressed, or hopeless |
| 3 | Trouble falling or staying asleep, or sleeping too much |
| 4 | Feeling tired or having little energy |
| 5 | Poor appetite or overeating |
| 6 | Feeling bad about yourself, or that you are a failure or have let yourself or your family down |
| 7 | Trouble concentrating on things, such as reading the newspaper or watching television |
| 8 | Moving or speaking so slowly that other people could have noticed. Or the opposite: being so fidgety or restless that you have been moving around a lot more than usual |
| 9 | Thoughts that you would be better off dead, or of hurting yourself in some way |

Steady leaves out the PHQ-9's unscored closing question about how difficult the problems have made work, home and getting along with people.

**Score**: the sum of the nine items, 0 to 27.

| Total | Band | Severity in Steady | A flag? |
|---|---|---|---|
| 0–4 | Minimal | None | No |
| 5–9 | Mild | Info | No |
| 10–14 | Moderate | Warn (amber) | Yes |
| 15–19 | Moderately severe | Alert (red) | Yes |
| 20–27 | Severe | Alert (red) | Yes |

**Item 9**: any answer above "Not at all" raises "Item 9 endorsed: review", alert (red), whatever the total. A result can carry both a band flag and the item 9 flag.

**Where it shows**: in your Alerts list ("[name] completed PHQ-9", with the score, band and any flag), on the result screen with every answer, on the patient's flags for 14 days, as a point on the RADR chart, and in exports. The patient never sees the score, band or flag. How flags are reviewed and what notifications say are in "Review flags, item 9 and notifications".

**Licence**: Pfizer makes the PHQ screeners free to use; no permission is required to reproduce, translate, display or distribute them. Steady marks it cleared.

## Item 9: what the evidence supports

Item 9 is sensitive but not specific. In 84,418 outpatients, each step up in item 9 was linked to a higher chance of a suicide attempt in the following year, from about 0.4% for "not at all" to about 4% for "nearly every day" (Simon et al. 2013). Against the C-SSRS in 841 patients, 41.1% endorsed item 9 against 13.4% positive on the C-SSRS; sensitivity was 87.6%, specificity 66.1%, positive predictive value 28.6% and negative predictive value 97.2% (Na et al. 2018). An endorsement is a reason to ask; it doesn't tell you how much risk there is, and a "Not at all" doesn't rule risk out.

## The PHQ-8

Some practices prefer not to send item 9 between sessions, when nobody may see the answer for hours. Each practice decides this, and how out-of-hours results are handled.

The PHQ-8 drops item 9, so its total runs from 0 to 24. In a large general-population survey, a PHQ-8 score of 10 or more worked as a definition of current depression (Kroenke et al. 2009), and an individual participant data meta-analysis found the PHQ-8 only slightly less sensitive than the PHQ-9 at a cut-off of 10 (about 0.03 lower), with nearly identical specificity (Wu et al. 2020).

In Steady, the PHQ-8 is imported from the ReproSchema library in your Library, where it is listed as free to use. **An imported PHQ-8 has at most a plain sum (when the library's own definition gives one) and no bands or flags**, so a high score raises no flag. Imported instruments can't be edited in the app, but "Use as a starting point for a new one" copies it into the questionnaire builder, where you can check the eight items are summed and add bands (for example the PHQ-9's, with the top band ending at 24, and amber from 10). The copy is saved as the practice's own and can be sent straight away; the import itself needs its licence confirmed first.

## Limits

- **A screening measure, not a diagnosis.** Steady never turns a PHQ-9 score into a diagnosis; neither should the bands.
- **Two-week recall.** Sent weekly, consecutive results overlap by a week.
- **Somatic items** (sleep, energy, appetite, slowing) also rise with physical illness, pain, pregnancy and medication.
- **No change scores.** Steady shows totals over time but doesn't calculate reliable or clinically significant change.
- **Validated in other populations.** The original and most meta-analytic samples are from North American and European primary care, not South African private practice.

Experience with the PHQ-9 and PHQ-8 between sessions, and with item 9 out of hours, is welcome in the replies.

## Where this lives

- `server/pb_hooks/lib/instruments.js`, `PHQ9`: the items, answers, bands, item 9 rule and licence
- `server/pb_hooks/lib/core.js`, `scoreAnswers` (scoring) and `reviewFlags` (flags)
- `server/pb_hooks/lib/instruments.js`, `REPROSCHEMA_CATALOG`, and `server/pb_hooks/lib/core.js`, `fromReproSchema` (the PHQ-8 import)

## References

- Kroenke K., Spitzer R.L., Williams J.B.W. (2001). The PHQ-9: validity of a brief depression severity measure. *Journal of General Internal Medicine* 16(9):606–613. https://doi.org/10.1046/j.1525-1497.2001.016009606.x
- Levis B., Benedetti A., Thombs B.D. (2019). Accuracy of Patient Health Questionnaire-9 (PHQ-9) for screening to detect major depression: individual participant data meta-analysis. *BMJ* 365:l1476. https://doi.org/10.1136/bmj.l1476
- Simon G.E. et al. (2013). Does response on the PHQ-9 Depression Questionnaire predict subsequent suicide attempt or suicide death? *Psychiatric Services* 64. https://doi.org/10.1176/appi.ps.201200587
- Na P.J. et al. (2018). The PHQ-9 Item 9 based screening for suicide risk: a validation study of the Patient Health Questionnaire (PHQ)-9 Item 9 with the Columbia Suicide Severity Rating Scale (C-SSRS). *Journal of Affective Disorders* 232:34–40. https://doi.org/10.1016/j.jad.2018.02.045
- Kroenke K. et al. (2009). The PHQ-8 as a measure of current depression in the general population. *Journal of Affective Disorders* 114(1–3):163–173. https://doi.org/10.1016/j.jad.2008.06.026
- Wu Y. et al. (2020). Equivalency of the diagnostic accuracy of the PHQ-8 and PHQ-9: a systematic review and individual participant data meta-analysis. *Psychological Medicine* 50(8):1368–1380. https://doi.org/10.1017/S0033291719001314
- Pfizer. Patient Health Questionnaire (PHQ) Screeners. https://www.phqscreeners.com/
