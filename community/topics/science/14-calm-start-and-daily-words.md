# The calm start and daily words

## What it is

Every time a patient opens Steady, they meet a quiet screen before anything else: a greeting, a sentence for the day, and a slowly breathing circle. Tapping the circle leads, one step at a time, to the day's check-in if there hasn't been one, then anything you have sent, then a short thank-you, and on to the home screen. Every patient screen moves at the same slow pace.

It is not a clinical intervention and makes no claim to be one. It is the setting in which every check-in and questionnaire is answered, which is why it is described here.

## How it came about

The calm start was added during Steady's beta at VR Clinical Psychology in October 2026, so that the patient side opens on a slow sequence rather than straight onto the home screen's lists. Two ideas lie behind it.

- **The way a patient arrives shapes what they report.** Opening onto lists of tasks invites hurried answers; a few seconds of slow breathing first asks for attention instead. This is a design judgement, not a finding.
- **The pace is borrowed from slow breathing.** The circle breathes in for 4 seconds and out for 6: 6 breaths a minute, with a longer out-breath. Slow breathing near 6 a minute is linked to higher heart rate variability and to reports of relaxation (Zaccaro et al. 2018), and about 6 a minute is close to most adults' resonance frequency (Lehrer and Gevirtz 2014). A few cycles before a check-in are not a dose of anything; the evidence is for practised breathing over minutes, not for this.

The daily words were written for Steady rather than taken from quotations, so nothing is misattributed and nothing needs a licence, and in a deliberately plain, gentle and realistic register rather than a cheerful one. Psychologists can add their own.

## How it works

### The sequence

1. **The quiet screen.** "Good morning", "Good afternoon" or "Good evening" with the patient's first name; the sentence for the day; the circle, labelled "Breathe in" and "Breathe out" as it moves; and "Breathe with the circle for a moment. Tap it when you're ready to check in." Tapping the circle (or "Skip") also starts a watch sync for patients who share watch data.
2. **The check-in**, if there hasn't been one that day: "How are you today? Take your time. There are no wrong answers." It can be skipped ("Skip the check-in").
3. **What you have sent**, one at a time ("1 of 2"), with your note if you wrote one, and a Begin button. Each can be left for later.
4. **Thank you**: "Taking a moment for yourself matters." After about 3 seconds, or a tap, the home screen.

If the patient has already checked in and nothing is waiting, tapping the circle goes straight to the home screen. The sequence runs each time the app opens, and again after the patient has been away from it for 5 minutes or more; a shorter trip to another app returns them to where they were.

### Pace

Behind every step, a soft glow swells and settles with the same 10-second breath. Pages fade in over about a second rather than sliding; pop-ups fade in more slowly than usual; notices, such as an app update, wait until the calm start has finished. If the phone is set to reduce motion, page changes are quick and text appears without fading in; the breathing circle and glow still move. Psychologists' screens keep normal, quicker transitions.

### The daily words

Steady has 60 built-in sentences, for example "A hard day is a day, not a verdict on you.", "Progress is rarely a straight line. Wobbles count." and "A thought is not a fact." Psychologists add their own under Library > Daily words (up to 240 characters each; quotations should name their author in the text), and can switch them off or delete them. A patient sees their own psychologist's sentences mixed in with the built-in ones, never another psychologist's.

The sentence is the same all day and changes the next. It is picked from the combined list by a fixed rule (the number of days since 1 January 2026, times 37, counted round the list), so consecutive days don't walk the list in order. Adding or removing a sentence changes which one appears on a given day.

## Limits

- **No evidence that it changes what patients report.** The calm start rests on design judgement and on research about practised slow breathing, not on a study of this screen.
- **It adds a step.** Patients who want to get straight in have to tap or skip each time; some will find it slow.
- **The words can miss.** A gentle sentence can land badly on a very bad day, and Steady can't choose words for a person's state. They are the same for every patient of one psychologist on a given day.
- **It can't be switched off** for a patient; it can only be skipped.
- **Breathing in time with the circle is optional** and not recorded. Nothing about the calm start is measured or sent to you.

Thoughts on the sentences, the pace, and whether the calm start helps or hinders your patients are welcome in the replies, as are new sentences.

## Where this lives

- `app/lib/ui/patient/daily_flow.dart`: `PatientGate` (when it runs) and `DailyFlow` (the steps, the 4 s in and 6 s out breath)
- `app/lib/content/daily_words.dart`: the 60 sentences and `wordsForToday`
- `app/lib/ui/calm.dart`: the slow pace for patient screens
- `app/lib/ui/clinician/daily_words_screen.dart` and the `quotes` collection in `server/pb_migrations/1761000000_steady_research.js` (psychologists' own sentences, seen by their own patients only)

## References

- Zaccaro A. et al. (2018). How breath-control can change your life: a systematic review on psycho-physiological correlates of slow breathing. *Frontiers in Human Neuroscience* 12:353. https://doi.org/10.3389/fnhum.2018.00353
- Lehrer P.M., Gevirtz R. (2014). Heart rate variability biofeedback: how and why does it work? *Frontiers in Psychology* 5:756. https://doi.org/10.3389/fpsyg.2014.00756
