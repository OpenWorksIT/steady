# The questionnaire system

## What it is

Every questionnaire in Steady, built in or added by a psychologist, is a written definition that the server checks, presents and scores in the same way. Four come built in: PHQ-9, GAD-7, PCL-5 and WHO-5 (each has its own topic). Psychologists can add more by writing one in the app, uploading a file, or importing a FHIR Questionnaire or an instrument from the open ReproSchema library.

## How it came about

VR Clinical Psychology wanted the standard instruments from the first day, and the freedom to create or upload their own. Rather than build each questionnaire into the app, Steady uses one format and one scoring engine for all of them, so a practice's own instrument is scored as openly as the PHQ-9, and anyone can read exactly how a score was reached. Licences are tracked in the same definition because many instruments are copyrighted, and a practice needs to know it may use one before it reaches a patient.

## How it works

### A definition

- **Items**: a choice (options with numeric values), a number (with a minimum and maximum), or free text. Items are required unless marked otherwise. An item can be shown only when an earlier answer meets a condition (for example, "show this if item 3 is 1 or more"); hidden items are never required.
- **Scoring**: a sum (the default) or a mean of the scored items (by default every choice and number item), times a multiplier if there is one (WHO-5 uses 4).
- **Bands**: score ranges with a label and a severity: none, info, warn (amber) or alert (red).
- **Subscales**: sums of listed items, reported beside the total.
- **Item flags**: a rule on one answer, such as PHQ-9 item 9 above 0, with a label and severity.
- **A note** shown with every result, for example the PCL-5's note that it has no official severity bands.

The builder in the app keeps to a subset: one answer scale for every question, a sum, bands, and an "at or above" flag on any question (always red). Conditional questions, subscales, a multiplier and different answers per question need an uploaded definition file; a copy made in the builder drops them, and says so.

### How a result is scored, exactly

1. The server checks the answers: every visible required item answered, each choice one of its options, each number within range, text cut to its limit. Answers to hidden items are dropped.
2. The total is the sum (or mean) of the scored items' values, times the multiplier, rounded to one decimal place.
3. A scored item left blank (only possible when it is optional) adds nothing. Steady does not prorate missing items.
4. The band is the first one whose range contains the total. A total outside every band gets no band.
5. Each item flag is checked on its own answer.
6. The result's severity is the highest of the band's and the flags'.
7. Subscales are plain sums of their items, without the multiplier.
8. The score is stored with the result when the patient sends it. Editing a definition later doesn't rescore earlier results.

### Who sees what

The patient sees the questions, the instructions and the instrument's licence line. They never see their score, band or flags: the server withholds them. You see the total and maximum, the band, subscales, the note, and each item with its answer, under the line "Scores support clinical judgement and are not a diagnosis." Results go into your Alerts list, the patient's flags (see "Review flags, item 9 and notifications"), the RADR chart beside the watch data, and exports, which include item-level answers.

### Licences

Each instrument has a licence status: **cleared**, **review**, **blocked** or **custom**. Only cleared and custom instruments can be sent.

- PHQ-9 and GAD-7 (Pfizer, free to use) and PCL-5 (public domain) ship cleared.
- WHO-5 ships as review. Its licence (CC BY-NC-SA 3.0 IGO) is non-commercial, so each practice confirms that it covers its own use before sending it.
- An instrument written in Steady is custom: the practice's own. So is an uploaded Steady file that the psychologist marks as their own work.
- Other uploads and all imports start at review. A psychologist confirms the practice may use the instrument by ticking a confirmation, and Steady records who and when.
- Blocked instruments, marked copyright protected in the ReproSchema library, can't be imported or cleared.

### Importing

**FHIR** (R4 or R5): groups are flattened and display-only items dropped. A choice takes its score from the `ordinalValue` or `itemWeight` extension, else a numeric code, else its position (0, 1, 2 and so on). Check the values after import. The scoring becomes a sum of every item.

**ReproSchema**: Steady lists 17 instruments from the library. Listed as free to use: PHQ-9, PHQ-8, PHQ-4, PHQ-15, GAD-7 and PC-PTSD-5. To check before use: EPDS, PROMIS Global Health, WHODAS 2.0 (12 items), Mood Disorder Questionnaire, CAGE-AID, Self-Compassion Scale (short form), MAAS, Daily Affect Scale and Internet Addiction Test. Blocked: the Inventory of Callous-Unemotional Traits (self-report and parent). Simple display rules are converted; more complex ones are dropped and those items become optional. A plain sum becomes the scoring. **Bands, item flags and subscales are not imported.** Imported instruments can't be edited in the app; to add them, use "Use as a starting point for a new one", which copies the instrument into the builder and saves the result as the practice's own (custom).

### Sending and repeats

You send an instrument once, daily or weekly, with an optional note to the patient (up to 280 characters). It is available at once, and the patient is told "From your psychologist". When the patient completes a repeating one, the next becomes available at the start of their next local day (daily), or seven days on (weekly), counted from when they completed it, not from when you first sent it. At 07:00 South African time, patients with something newly available are told "Ready for today". Patients can't start a questionnaire themselves, and stopping a patient's access cancels everything waiting.

## Limits

- **The engine scores what it is told.** A mistyped band or option value in a definition gives wrong results, consistently. Check created and imported instruments before sending them.
- **No prorating.** An optional scored item left blank lowers the total.
- **Weekly repeats drift** when a patient completes late: a Wednesday questionnaire finished on Friday next appears on the following Friday.
- **Bands are screening cut-points** from the instrument's own literature. They are not diagnoses, and most were set in populations unlike a South African private practice.
- **Imports can be incomplete**: reverse-scored items are right only if the option values say so, and bands and flags must be added in a copy.
- **A copy becomes the practice's own.** Saving a copy of a third-party instrument as custom makes it sendable without a licence check, so check its licence yourself first.
- **Language**: definitions carry a language, but the built-in instruments are in English only.

Questions about the format, the engine or the licence rules are welcome below.

## Where this lives

- `server/pb_hooks/lib/core.js`: `validateInstrument`, `normaliseScoring`, `validateAnswers`, `isVisible`, `scoreAnswers`, `nextAvailable`, `fromFhirQuestionnaire`, `fromReproSchema`
- `server/pb_hooks/lib/instruments.js`: `BUILTIN` and `REPROSCHEMA_CATALOG`
- `server/pb_hooks/steady.pb.js`: the `/api/steady/instruments` routes, `/api/steady/assignments/{id}/complete`, and the `steady_due_today` schedule
- `server/pb_hooks/lib/server.js`, `sendable`; `server/pb_hooks/steady_privacy.pb.js` (scores withheld from patients)
- `docs/QUESTIONNAIRE_FORMAT.md`: the format, with examples

## References

- HL7 International. Questionnaire, FHIR R4 (v4.0.1). http://hl7.org/fhir/R4/questionnaire.html
- Chen Y. et al. (2025). Standardizing survey data collection to enhance reproducibility: development and comparative evaluation of the ReproSchema ecosystem. *Journal of Medical Internet Research* 27:e63343. https://doi.org/10.2196/63343
- de Jong K. et al. (2021). Using progress feedback to improve outcomes and reduce drop-out, treatment duration, and deterioration: a multilevel meta-analysis. *Clinical Psychology Review* 85:102002. https://doi.org/10.1016/j.cpr.2021.102002
