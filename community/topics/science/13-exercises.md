# Breathing and other exercises

## What they are

Steady has five built-in exercises a psychologist can send, and a patient can also start on their own from "Whenever you need it" on the home screen: three paced-breathing exercises and two step-by-step ones. Psychologists can write their own of either kind.

| Exercise | Pattern | Length as built |
|---|---|---|
| Box breathing | In 4 s, hold 4 s, out 4 s, hold 4 s; 6 rounds | 96 seconds |
| 4-7-8 breathing | In 4 s, hold 7 s, out 8 s; 4 rounds | 76 seconds |
| Slow paced breathing | In 4 s, out 6 s; 18 rounds (6 breaths a minute) | 3 minutes |
| 5-4-3-2-1 grounding | Five steps: see, feel, hear, smell, taste | Untimed ("about 4 minutes") |
| Thought record | Five steps: situation, thought, feeling (0 to 100), alternative, feeling again | Untimed ("about 5 minutes") |

## How they came about

VR Clinical Psychology's brief included being able to send exercises, breathing among them. The built-in set covers three common needs: slowing the breath, coming back to the present, and working with a thought. The texts and timings are OpenWorks IT's own wording (published under Steady's AGPL licence), signed off by VR Clinical Psychology, so they need no outside licence.

**Slow breathing has the clearest evidence.** A systematic review of 15 studies of breathing slowed below 10 breaths a minute, most at about 6, found more heart rate variability and reports of relaxation, comfort and lower anxiety, but also small samples, no randomised controlled designs and some null results (Zaccaro et al. 2018). About 6 breaths a minute is near most adults' resonance frequency, where heart rate oscillations are largest (Lehrer and Gevirtz 2014). Steady's slow paced breathing (4 in, 6 out) sits exactly at 6 a minute, with a longer out-breath.

**Breathwork in general helps a little.** A meta-analysis of 12 randomised trials (785 adults) found breathwork lowered self-reported stress compared with controls, a small-to-medium effect (g = −0.35), with similar effects on anxiety and depressive symptoms; most trials were at moderate risk of bias (Fincham et al. 2023).

**Box breathing** was one arm of a remote randomised study of five minutes a day for 28 days in 108 people. It raised positive affect, but not significantly more than mindfulness meditation; cyclic sighing, which Steady doesn't include, did best (Balban et al. 2023).

**4-7-8 breathing** has very little research: one small study of 44 young adults found lower heart rate and blood pressure after a session (Vierra et al. 2022).

**Grounding (5-4-3-2-1)** is widely used in trauma-focused and anxiety work. We found no controlled trial of it; it is included on clinical judgement.

**Thought records** are a standard cognitive therapy tool. In one randomised experiment with 91 non-clinical participants, a single thought record improved beliefs, anxiety and behaviour compared with a control condition, and a behavioural experiment did slightly better (McManus et al. 2012).

## How they work

**Breathing.** After 1.2 seconds of "Get comfortable", a circle grows over each in-breath and shrinks over each out-breath, holding its size through holds, with the phase's name ("Breathe in", "Hold", "Breathe out"), a countdown in seconds, and "Round N of M". With reduced motion turned on in the phone, the circle doesn't move and the words and countdown carry the pace. "Finish early" ends it at any point. Steady records the rounds completed and the time taken.

**Steps.** One step at a time: a title, a prompt, and an optional box to write in (up to 2,000 characters), with Back and Next. Steady records what was written for each step, which may be nothing. The thought record's 0 to 100 ratings are written as text, not scored.

**Sending and starting.** You can send an exercise once, daily or weekly, with a note, like a questionnaire. A patient can start a built-in exercise themselves at any time, and one of your own only after you have sent it to them. Crisis numbers are at the foot of every exercise screen.

**What you see.** For an exercise you sent: an item in your Alerts list and a push ("Exercise finished in N min"), and on its result, the rounds and time or each written answer. For one the patient started themselves: an item in your Alerts list ("Started by the patient") but no push. Exports list exercises done, with minutes for breathing.

**Your own.** In the builder: a breathing exercise with phases of 1 to 30 seconds and 1 to 60 rounds, or a steps exercise with a title and prompt per step.

## Limits

- **No outcome is measured.** Steady records that an exercise was done, not whether it helped. Pairing it with the check-in, or asking in session, is the only measure.
- **Holds don't suit everyone.** Box and 4-7-8 breathing include breath holds of 4 and 7 seconds; for some people, for example during panic or with breathing or heart conditions, holds can be uncomfortable. Slow paced breathing has none. Choose with the patient.
- **Fixed pacing.** The timings suit most adults but not all; resonance frequency varies between people, and Steady doesn't find each patient's.
- **Thin evidence for two of the five.** 4-7-8 and grounding rest on clinical use more than on trials.
- **Written answers aren't read by Steady.** A thought record can contain distressing content; it reaches you like any result, without a flag.

Experience with which exercises patients actually use, and suggestions for new ones, are welcome in the replies.

## Where this lives

- `server/pb_hooks/lib/instruments.js`: `BOX`, `B478`, `PACED`, `GROUND`, `THOUGHT`
- `server/pb_hooks/lib/core.js`: `validateInstrument` (exercise limits) and `validateExerciseResult` (what is recorded)
- `app/lib/ui/patient/activity_screens.dart`: `BreathingScreen` and `StepsScreen`
- `server/pb_hooks/steady.pb.js`: `/api/steady/self-start` and `/api/steady/assignments/{id}/complete`

## References

- Zaccaro A. et al. (2018). How breath-control can change your life: a systematic review on psycho-physiological correlates of slow breathing. *Frontiers in Human Neuroscience* 12:353. https://doi.org/10.3389/fnhum.2018.00353
- Lehrer P.M., Gevirtz R. (2014). Heart rate variability biofeedback: how and why does it work? *Frontiers in Psychology* 5:756. https://doi.org/10.3389/fpsyg.2014.00756
- Fincham G.W. et al. (2023). Effect of breathwork on stress and mental health: a meta-analysis of randomised-controlled trials. *Scientific Reports* 13:432. https://doi.org/10.1038/s41598-022-27247-y
- Balban M.Y. et al. (2023). Brief structured respiration practices enhance mood and reduce physiological arousal. *Cell Reports Medicine* 4(1):100895. https://doi.org/10.1016/j.xcrm.2022.100895
- Vierra J. et al. (2022). Effects of sleep deprivation and 4-7-8 breathing control on heart rate variability, blood pressure, blood glucose, and endothelial function in healthy young adults. *Physiological Reports*. https://doi.org/10.14814/phy2.15389
- McManus F., Van Doorn K., Yiend J. (2012). Examining the effects of thought records and behavioral experiments in instigating belief change. *Journal of Behavior Therapy and Experimental Psychiatry* 43(1):540–547. https://doi.org/10.1016/j.jbtep.2011.07.003
