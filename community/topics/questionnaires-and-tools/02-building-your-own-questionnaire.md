# Building your own questionnaire

Steady lets you write questionnaires and exercises of your own, and send them like the built-in ones. The Steady manual walks through it step by step; this is the overview, with what's worth knowing before you start.

## Where

Settings > Practice > Library > **Add** > **Create a questionnaire or exercise**. Then choose **Questionnaire**, **Steps** (an exercise of prompts, one at a time) or **Breathing** (a paced breathing pattern).

## A questionnaire, part by part

- **Short name**, used everywhere, and an optional **full name**.
- **One line patients see** (optional), such as "5 questions, about 2 minutes".
- **Instructions**, such as "Over the last 2 weeks, how often...".
- **Answer options**: one scale for every choice question. Start from a preset (How often 0–3, Agreement 0–4, How much 0–4, or Yes/No) and change the labels and scores as you need.
- **Questions**: each one is a choice from the options, a written answer or a number, and required or not. A choice question can have a **flag for review when the score is at least** a value you set; that answer is then flagged in red, as PHQ-9 item 9 is.
- **Scoring**: add up the option scores and, if you want, name **score bands**: from, to, a label, and how to show it (plain, note, amber or red). Amber and red bands are flagged for review, as the built-in ones are.

**Save to library**, and it's ready to send, marked Own.

## Exercises

- **Steps**: a heading and a prompt for each step. Patients go through them one at a time, with an optional box to write in.
- **Breathing**: phases such as breathe in, hold and breathe out, each 1 to 30 seconds, with the circle growing or shrinking, repeated for 1 to 60 rounds.

## Worth knowing

- **Start from an existing one.** Tap any questionnaire in the library and choose "Use as a starting point for a new one". The editor keeps things simple, so conditional questions, sub-scores, different options per question and score multipliers aren't carried over, and it tells you so. Check the copy before you send it.
- **Editing.** You can edit what you created in Steady. Earlier answers stay linked to their questions, so if a question's meaning changes, make a new questionnaire instead.
- **Archiving.** Archive what you no longer use; it moves to Archived in the library.
- **More than the editor does.** Conditional questions, sub-scales and score multipliers can be written as a Steady questionnaire file and imported (Library > Add > Import). The format is in [Steady's questionnaire format](https://github.com/OpenWorksIT/steady/blob/main/docs/QUESTIONNAIRE_FORMAT.md), with [an example file](https://github.com/OpenWorksIT/steady/blob/main/docs/examples/session-feedback.steady.json). OpenWorks IT can help with files in Steady development.
- **Bands are a claim.** A band's label tells whoever reads the result what a score means. For a new questionnaire, consider leaving bands out until you have data to set them by.
- **For everyone.** What the community builds together can go into Steady for every practice, once VR Clinical Psychology has signed it off, as it does all of Steady's clinical content.

What have you built so far? And what did the editor not let you do?
