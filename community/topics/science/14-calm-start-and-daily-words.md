# The calm start and daily words

## What it is

Every time a patient opens Steady, they meet a quiet screen before anything else: a greeting, a sentence for the day, and a slowly breathing circle. Tapping the circle leads, one step at a time, to the day's check-in if there hasn't been one, then anything you have sent, then a short thank-you, and on to the home screen. Every patient screen moves at the same slow pace.

It is not a clinical intervention and makes no claim to be one. It is the setting in which every check-in and questionnaire is answered, which is why it is described here.

## How it came about

The calm start was added during Steady's beta at VR Clinical Psychology in October 2026, so that the patient side opens on a slow sequence rather than straight onto the home screen's lists. Two ideas lie behind it.

- **The way a patient arrives shapes what they report.** Opening onto lists of tasks invites hurried answers; a few seconds of slow breathing first asks for attention instead. This is a design judgement, not a finding.
- **The pace is borrowed from slow breathing.** The circle breathes in for 4 seconds and out for 6: 6 breaths a minute, with a longer out-breath. Slow breathing near 6 a minute is linked to higher heart rate variability and to reports of relaxation (Zaccaro et al. 2018), and about 6 a minute is close to most adults' resonance frequency (Lehrer and Gevirtz 2014). A few cycles before a check-in are not a dose of anything; the evidence is for practised breathing over minutes, not for this.

The daily words were written for Steady rather than taken from quotations, so nothing is misattributed and nothing needs a licence, and in a deliberately plain, gentle and realistic register rather than a cheerful one. Clinicians can add their own.

In November 2026 Kempie van Rooyen checked them against the evidence. None was unscientific: they work as supportive encouragement and values statements, and nothing claims that a line on its own prevents relapse. Their non-judgemental tone fits relapse-prevention models, which treat a lapse as a chance to reassess rather than a personal failure ([Relapse Prevention](https://pmc.ncbi.nlm.nih.gov/articles/PMC6760427)). Steady 1.3.0 reworded a few so that:

- **no line predicts how someone will feel or what happens next**: "Beginning is how ready arrives" became "A small first step may help you feel more ready"; "This one will change too" became "This one may shift, even if only a little"; "You're doing better than your worries say" became "Your worries may not tell the whole story";
- **carrying on isn't always the goal**: "Steady doesn't mean perfect. It means you keep going" became "…You can pause, seek support, and begin again"; "Take care of the next hour. That's all" became "Take the next hour one step at a time. Reach out if you need support";
- **body-focused prompts are invitations, with another way**: mindfulness can be uncomfortable for some people ([What Are Adverse Events in Mindfulness Meditation?](https://pmc.ncbi.nlm.nih.gov/articles/PMC9024164)), so "Breathe out a little longer…", "Unclench your jaw…", "Feel your feet on the ground…" and "Settle into this breath…" now start "If it feels comfortable…" and offer looking around instead, and the circle says "Breathe with the circle if you like, or just rest your eyes on it."

Because one message doesn't suit everyone (a strongly positive self-statement left people with low self-esteem feeling worse: [Positive self-statements: power for some, peril for others](https://pubmed.ncbi.nlm.nih.gov/19493324)), patients can hide a line they'd rather not see again ("Not for me: hide these words"), or switch the words off in Settings. They are supportive check-in prompts, not a structured relapse-prevention intervention, which works on high-risk situations and planned responses ([CBT for Substance Use Disorders](https://pmc.ncbi.nlm.nih.gov/articles/PMC2897895)), and sit alongside the coping plans you make together.

## How it works

### The sequence

1. **The quiet screen.** "Good morning", "Good afternoon" or "Good evening" with the patient's first name; the sentence for the day; the circle, labelled "Breathe in" and "Breathe out" as it moves; and "Breathe with the circle if you like, or just rest your eyes on it. Tap it when you're ready to check in." Under the sentence, "Not for me: hide these words" hides it on that phone for good. Tapping the circle (or "Skip") also starts a watch sync for patients who share watch data.
2. **The check-in**, if there hasn't been one that day: "How are you today? Take your time. There are no wrong answers." It can be skipped ("Skip the check-in").
3. **What you have sent**, one at a time ("1 of 2"), with your note if you wrote one, and a Begin button. Each can be left for later.
4. **Thank you**: "Taking a moment for yourself matters." After about 3 seconds, or a tap, the home screen.

If the patient has already checked in and nothing is waiting, tapping the circle goes straight to the home screen. The sequence runs each time the app opens, and again after the patient has been away from it for 5 minutes or more; a shorter trip to another app returns them to where they were.

### Pace

Behind every step, a soft glow swells and settles with the same 10-second breath. Pages fade in over about a second rather than sliding; pop-ups fade in more slowly than usual; notices, such as an app update, wait until the calm start has finished. If the phone is set to reduce motion, page changes are quick and text appears without fading in; the breathing circle and glow still move. Clinicians' screens keep normal, quicker transitions.

### The daily words

Steady has 60 built-in sentences, for example "A hard day is a day, not a verdict on you.", "Progress is rarely a straight line. Wobbles count." and "A thought is not a fact." Clinicians add their own under Library > Daily words (up to 240 characters each; quotations should name their author in the text), and can switch them off or delete them. A patient sees their own clinician's sentences mixed in with the built-in ones, never another clinician's.

The sentence is the same all day and changes the next. It is picked from the combined list by a fixed rule (the number of days since 1 January 2026, times 37, counted round the list), so consecutive days don't walk the list in order. Adding or removing a sentence changes which one appears on a given day.

## Limits

- **No evidence that it changes what patients report.** The calm start rests on design judgement and on research about practised slow breathing, not on a study of this screen.
- **It adds a step.** Patients who want to get straight in have to tap or skip each time; some will find it slow.
- **The words can miss.** A gentle sentence can land badly on a very bad day, and Steady can't choose words for a person's state. They are the same for every patient of one clinician on a given day.
- **The calm start can't be switched off** for a patient; it can only be skipped. The words can: patients switch them off in Settings, or hide one line at a time (kept on their phone, and not sent to you).
- **Breathing in time with the circle is optional** and not recorded. Nothing about the calm start is measured or sent to you.

Thoughts on the sentences, the pace, and whether the calm start helps or hinders your patients are welcome in the replies, as are new sentences.

## Where this lives

- `app/lib/ui/patient/daily_flow.dart`: `PatientGate` (when it runs) and `DailyFlow` (the steps, the 4 s in and 6 s out breath)
- `app/lib/content/daily_words.dart`: the 60 sentences, `wordsForToday` and `DailyWordsPrefs` (what a patient hid or switched off)
- `app/lib/ui/calm.dart`: the slow pace for patient screens
- `app/lib/ui/clinician/daily_words_screen.dart` and the `quotes` collection in `server/pb_migrations/1761000000_steady_research.js` (clinicians' own sentences, seen by their own patients only)

## References

- Larimer M.E., Palmer R.S., Marlatt G.A. (1999). Relapse prevention: an overview of Marlatt's cognitive-behavioral model. *Alcohol Research & Health* 23(2):151–160. https://pmc.ncbi.nlm.nih.gov/articles/PMC6760427
- What are adverse events in mindfulness meditation? https://pmc.ncbi.nlm.nih.gov/articles/PMC9024164
- Wood J.V., Perunovic W.Q.E., Lee J.W. (2009). Positive self-statements: power for some, peril for others. *Psychological Science* 20(7):860–866. https://pubmed.ncbi.nlm.nih.gov/19493324
- Cognitive-behavioral therapy for substance use disorders. https://pmc.ncbi.nlm.nih.gov/articles/PMC2897895

- Zaccaro A. et al. (2018). How breath-control can change your life: a systematic review on psycho-physiological correlates of slow breathing. *Frontiers in Human Neuroscience* 12:353. https://doi.org/10.3389/fnhum.2018.00353
- Lehrer P.M., Gevirtz R. (2014). Heart rate variability biofeedback: how and why does it work? *Frontiers in Psychology* 5:756. https://doi.org/10.3389/fpsyg.2014.00756
