# About the Science section
<!-- steady: pinned -->

This section sets out how Steady's clinical methods work, one topic per system. Each topic is a short manual: what the system is, how it came about and the evidence behind it, how it works exactly as built (items, scales, scores, thresholds and timings), where it is weak, and its references. The topics describe Steady 1.1.0.

The aim is simple: when you see a number, a flag or a patient's place in your list, you should be able to find out precisely what produced it before you lean on it.

## What is here

| Topic | What it covers |
|---|---|
| The daily check-in | The four ratings and the few words patients write |
| Review flags, item 9 and notifications | What raises a flag, how you mark it as reviewed, and what reaches your phone |
| The questionnaire system | How any questionnaire is defined, scored, banded, licensed and scheduled |
| PHQ-9 (and PHQ-8), GAD-7, PCL-5, WHO-5 | One topic each: items, scoring, bands and sources |
| Watch and phone data | What is read, how a day is summarised, and the usual range |
| RADR, in three topics | The evidence behind it, how a day is rated, and its flags, reviews and limits |
| How the patient list is ordered | Including the 14-day view and "Stable, ease off" |
| Breathing and other exercises | The five built-in exercises |
| The calm start and daily words | What patients see each time they open Steady |

## How to read a topic

Every topic ends the same way. **Where this lives** names the files and functions in Steady's source code (github.com/OpenWorksIT/steady) that do what the topic describes, so anyone can check it. If a topic and the code ever disagree, the code is what runs: the topic is then wrong and will be corrected.

Every reference was checked before it was used, and links to the original paper where there is one. Where the evidence is thin, or where a number is a judgement rather than a finding, the topic says so.

Steady never diagnoses. Scores, bands, flags and RADR support your judgement. None of them is a diagnosis, a risk score or a prediction, and nothing in Steady is watched around the clock.

## Who decides

VR Clinical Psychology signs off the science and clinical content of every Steady deployment: which questionnaires ship, how they are scored and banded, what is flagged, and the clinical wording that patients and psychologists read. OpenWorks IT writes and runs the code to match. Kempie van Rooyen leads this community.

A change to a method follows the same path each time: a short proposal with its reasons and evidence, discussion, written sign-off from VR Clinical Psychology, then building, testing and release. A method that carries a version name gets a new one when it changes (RADR is `radr-1` today), and exports state which version produced their numbers, so a file read later still says how it was made.

## How to discuss or challenge a method

- Reply in the topic it concerns, and say which part you mean: an item, a threshold, a timing, a reference.
- Bring evidence where you can: a paper with a link, or a pattern from your own practice described in aggregate or through a made-up example.
- Disagreement is welcome. Several numbers, RADR's especially, are reasoned starting points that are meant to be tested.
- Never post anything that could identify a patient. The examples in these topics are invented; please keep to that.
- OpenWorks IT reads this section and can reply here, but can't read the clinical areas of this forum (Clinical practice, Research and studies, Questionnaires and tools, the Tea room). When a discussion here ends in a proposed change to Steady, the person who raised it, or the community lead, posts the proposal in Steady development, where it's tracked.

## Methods will change

Steady is developed with the psychologists who use it, and its methods will move as practices report what works and what doesn't. When the code changes, the topic is edited to match, and a reply in the topic records what changed and when, so the history stays readable.

Questions about this section itself are welcome in the replies below.

## Where this lives

- The source code: github.com/OpenWorksIT/steady
- The method notes the topics draw on: `docs/RADR.md`, `docs/QUESTIONNAIRE_FORMAT.md`, `docs/PRIVACY.md`
- The patient consent statement: `server/pb_hooks/content/consent.md`

## References

None for this topic; each of the following topics lists its own.
