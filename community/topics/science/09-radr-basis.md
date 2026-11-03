# RADR: what it is and the evidence behind it

## What it is

RADR, the Research Amon Dîn Rating, shows day by day how far a patient's watch data and check-ins are from that person's own usual, to improve care. It groups the watch data into four areas (sleep, body clock, activity and heart), keeps the check-ins beside them rather than inside them, and asks whether the two move together. It appears in the patient's RADR tab, and it helps order your patient list.

**RADR is not a risk score, a prediction or a diagnosis.** It is not watched around the clock, nothing is triggered by it, and nothing about it is sent as a notification. In your list it only orders patients, and always below answers waiting for review, such as PHQ-9 item 9. Every number it shows can be opened to see how it was worked out.

This topic covers why RADR is built as it is. "RADR: how a day is rated" gives the method exactly, and "RADR: flags, reviews, the list and the limits" covers how it is used and where it falls short. The method's version is `radr-1`.

## Who approved it

Kempie van Rooyen (VR Clinical Psychology) approved RADR for use in care. The ethics approval for research use, and its consent, sit with him. Patients agree to share watch data separately, in the watch consent (`wearable-2`), which says the data may be added to their clinical record and used, without their name, to improve care; the patient consent statement says the psychologist may compare check-ins and watch data with the patient's own usual pattern. If another practice wants to use RADR data for research beyond care, that practice decides whether it needs its own ethics approval and a research consent.

## What the research says

RADR applies, in ordinary care, what studies of passive watch data report. In short:

**Single watch measures say little on their own; combinations do better.** In 267 Fitbit wearers, single measures correlated only weakly with PHQ-9 (absolute ρ 0.12 to 0.26), and models that combined selected measures across categories beat any single category (Rykov et al. 2021).

**Each person is best compared with themselves.** In 168 people with mood disorders, models built from sleep-wake data alone predicted next-day depressive episodes with an AUC of 0.80 (manic 0.98, hypomanic 0.95); daily shifts of the body clock were the strongest predictor, with delays linked to depressive episodes and advances to manic ones (Lim et al. 2024). In 31 adults with major depression followed for eight weeks, each person's own median did at least as well as the machine-learning models at tracking clinician-rated severity (Pedrelli et al. 2020). In the e-Prevention challenge on psychotic relapse from smartwatch data (Zlatintsi et al. 2024), methods such as Tsalkitzis et al. (2026) learn each patient's own stable period and score departures from it; the results so far are modest, with AUCs around 0.6.

**Sleep timing and regularity carry signal for suicidal ideation.** In 50 young adults at high suicide risk, night-to-night variability of sleep timing, measured by actigraphy, predicted increases in suicidal ideation over 21 days, over and above depressive symptoms (Bernert et al. 2017). Short and poor sleep predicted next-day suicidal ideation (Littlewood et al. 2019). In 91,105 UK Biobank participants, a disrupted daily rest-activity rhythm was associated with mood disorders and lower wellbeing (Lyall et al. 2018).

**Heart measures add something, in small studies.** In a pilot with a Galaxy Watch Active2 (activity, sleep, heart rate and heart rate variability) in 39 patients with depression and 20 controls, imminent suicide risk was identified with an AUC of 0.89, with heart rate variability among the top predictors (Um et al. 2025).

**But passive data has not yet beaten asking.** A systematic review found passive sensing generally performed below actively reported data, and three of the four studies that tested it found no added value from it (Büscher et al. 2024). In 2,459 medical interns, models using daily mood alone predicted depression and suicidal ideation best; adding wearable data didn't help (Horwitz et al. 2023). In psychiatric inpatients, wearable-only and clinical-only models performed similarly, and combining them roughly doubled recall (Lee et al. 2026). In 66 inpatients on acute wards, the best phone and Fitbit model reached an AUC of only 0.65, and a self-reported feeling rating was the most important feature in the authors' example decision tree, with time in bed second (Haines-Delmont et al. 2020).

## The design decisions

| Decision | Why |
|---|---|
| Four domains combined, not one measure | Single measures are weak (Rykov 2021) |
| Each person against their own recent weeks | Personal baselines do at least as well as models (Pedrelli 2020), and relapse work uses each patient's stable period (e-Prevention) |
| A separate body-clock domain | Circadian shifts were the strongest predictor (Lim 2024; Lyall 2018) |
| Sleep length and sleep irregularity | Bernert 2017; Littlewood 2019 |
| Check-ins kept beside the watch, with equal weight in the combined score | Asking does at least as well (Büscher 2024; Horwitz 2023; Lee 2026) |
| A test of whether the watch moves with, or before, the check-ins | That is the open question RADR exists to answer in this practice |
| No trained model, no population norms | Too little data to train on; norms differ between people and devices |
| Ordering, never alerting | The evidence supports looking sooner, not acting on a score |

Two inputs were considered and left out. **Sleep stages**: changes are not specific to depression even in the laboratory (Baglioni et al. 2016), and wrist devices stage sleep poorly (Schyvens et al. 2024). **Heart rate variability**: the method has a place for it in the heart domain, but Steady doesn't collect it (see "Watch and phone data"), so the heart domain rests on resting heart rate alone.

None of these studies used the same watches, measures or people as a South African private practice. Most were small, short and single-centre. RADR borrows their direction and structure, not their thresholds or accuracy figures, and its own numbers are starting points to be tested.

Challenges to any of these choices, and papers that bear on them, are welcome in the replies.

## Where this lives

- `server/pb_hooks/lib/radr.js`: the method (`rate`, `dayRating`) and the plain-words reasons shown in the app (`WHY`)
- `server/pb_hooks/lib/core.js`, `attention`: RADR's place in the list, below answers
- `docs/RADR.md`: the method note
- `app/lib/ui/patient/watch_screens.dart`, `ConnectWatchScreen` (watch consent) and `server/pb_hooks/content/consent.md` (consent statement)

## References

- Rykov Y. et al. (2021). Digital biomarkers for depression screening with wearable devices: cross-sectional study with machine learning modeling. *JMIR mHealth and uHealth* 9(10):e24872. https://doi.org/10.2196/24872
- Lim D. et al. (2024). Accurately predicting mood episodes in mood disorder patients using wearable sleep and circadian rhythm features. *npj Digital Medicine* 7. https://doi.org/10.1038/s41746-024-01333-z
- Pedrelli P. et al. (2020). Monitoring changes in depression severity using wearable and mobile sensors. *Frontiers in Psychiatry* 11:584711. https://doi.org/10.3389/fpsyt.2020.584711
- Zlatintsi A. et al. (2024). Person identification and relapse detection from continuous recordings of biosignals challenge: overview and results. *IEEE Open Journal of Signal Processing* 5:641–651. https://doaj.org/article/ac7f0b06f1a045adb26b40e7f8ddba4a
- Tsalkitzis N., Filntisis P.P., Maragos P., Efthymiou N. (2026). Uncertainty-driven anomaly detection for psychotic relapse using smartwatches: forecasting and multi-task learning fusion. arXiv preprint 2605.13816. https://arxiv.org/abs/2605.13816
- Bernert R.A., Hom M.A., Iwata N.G., Joiner T.E. (2017). Objectively assessed sleep variability as an acute warning sign of suicidal ideation in a longitudinal evaluation of young adults at high suicide risk. *Journal of Clinical Psychiatry* 78(6):e678–e687. https://doi.org/10.4088/JCP.16m11193
- Littlewood D.L. et al. (2019). Short sleep duration and poor sleep quality predict next-day suicidal ideation: an ecological momentary assessment study. *Psychological Medicine* 49(3):403–411. https://doi.org/10.1017/S0033291718001009
- Lyall L.M. et al. (2018). Association of disrupted circadian rhythmicity with mood disorders, subjective wellbeing, and cognitive function: a cross-sectional study of 91 105 participants from the UK Biobank. *The Lancet Psychiatry* 5(6):507–514. https://doi.org/10.1016/S2215-0366(18)30139-1
- Um J. et al. (2025). Machine learning models to identify individuals with imminent suicide risk using a wearable device: a pilot study. *Psychiatry Investigation* 22(2):156–166. https://doi.org/10.30773/pi.2024.0257
- Büscher R. et al. (2024). A systematic review on passive sensing for the prediction of suicidal thoughts and behaviors. *npj Mental Health Research* 3:42. https://doi.org/10.1038/s44184-024-00089-4
- Horwitz A.G. et al. (2023). Using machine learning with intensive longitudinal data to predict depression and suicidal ideation among medical interns over time. *Psychological Medicine* 53(12):5778–5785. https://doi.org/10.1017/S0033291722003014
- Lee Y. et al. (2026). Use of ecological momentary assessment via wearable devices for detecting acute suicide risk in psychiatric inpatients. *Frontiers in Psychiatry* 17:1849140. https://doi.org/10.3389/fpsyt.2026.1849140
- Haines-Delmont A. et al. (2020). Testing suicide risk prediction algorithms using phone measurements with patients in acute mental health settings: feasibility study. *JMIR mHealth and uHealth* 8(6):e15901. https://doi.org/10.2196/15901
- Baglioni C. et al. (2016). Sleep and mental disorders: a meta-analysis of polysomnographic research. *Psychological Bulletin* 142. https://doi.org/10.1037/bul0000053
- Schyvens A.M. et al. (2024). Accuracy of Fitbit Charge 4, Garmin Vivosmart 4, and WHOOP versus polysomnography: systematic review. *JMIR mHealth and uHealth* 12:e52192. https://doi.org/10.2196/52192
