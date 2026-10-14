/*
 * Steady - built-in instruments.
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Plain CommonJS so the same file is used by PocketBase (pb_migrations, pb_hooks)
 * and by the Node test suite. Keep to ES2015 syntax (no optional chaining) for goja.
 *
 * Licence notes are factual summaries for clinicians; the practice remains responsible
 * for confirming its own right to use each instrument.
 */

var FREQ4 = [
  { label: "Not at all", value: 0 },
  { label: "Several days", value: 1 },
  { label: "More than half the days", value: 2 },
  { label: "Nearly every day", value: 3 }
];

var PCL5 = [
  { label: "Not at all", value: 0 },
  { label: "A little bit", value: 1 },
  { label: "Moderately", value: 2 },
  { label: "Quite a bit", value: 3 },
  { label: "Extremely", value: 4 }
];

var WHO5 = [
  { label: "All of the time", value: 5 },
  { label: "Most of the time", value: 4 },
  { label: "More than half of the time", value: 3 },
  { label: "Less than half of the time", value: 2 },
  { label: "Some of the time", value: 1 },
  { label: "At no time", value: 0 }
];

function items(prefix, texts, set) {
  return texts.map(function (t, i) {
    return { id: prefix + "_" + (i + 1), text: t, type: "choice", responseSet: set, required: true };
  });
}

function ids(prefix, from, to) {
  var out = [];
  for (var i = from; i <= to; i++) out.push(prefix + "_" + i);
  return out;
}

var PHQ9 = {
  key: "phq9",
  name: "PHQ-9",
  fullName: "Patient Health Questionnaire-9",
  kind: "questionnaire",
  version: "1",
  language: "en",
  summary: "Depression symptoms, 9 items, about 3 minutes",
  instructions: "Over the last 2 weeks, how often have you been bothered by any of the following problems?",
  responseSets: { freq4: FREQ4 },
  items: items("phq9", [
    "Little interest or pleasure in doing things",
    "Feeling down, depressed, or hopeless",
    "Trouble falling or staying asleep, or sleeping too much",
    "Feeling tired or having little energy",
    "Poor appetite or overeating",
    "Feeling bad about yourself, or that you are a failure or have let yourself or your family down",
    "Trouble concentrating on things, such as reading the newspaper or watching television",
    "Moving or speaking so slowly that other people could have noticed. Or the opposite: being so fidgety or restless that you have been moving around a lot more than usual",
    "Thoughts that you would be better off dead, or of hurting yourself in some way"
  ], "freq4"),
  scoring: {
    method: "sum",
    max: 27,
    bands: [
      { min: 0, max: 4, label: "Minimal", severity: "none" },
      { min: 5, max: 9, label: "Mild", severity: "info" },
      { min: 10, max: 14, label: "Moderate", severity: "warn" },
      { min: 15, max: 19, label: "Moderately severe", severity: "alert" },
      { min: 20, max: 27, label: "Severe", severity: "alert" }
    ],
    itemFlags: [
      { item: "phq9_9", op: ">", value: 0, label: "Item 9 endorsed: review", severity: "alert" }
    ]
  },
  licence: {
    name: "Pfizer: free to use, no permission required to reproduce, translate, display or distribute",
    status: "cleared",
    url: "https://www.phqscreeners.com/"
  },
  source: { name: "Built in", url: "https://www.phqscreeners.com/" }
};

var GAD7 = {
  key: "gad7",
  name: "GAD-7",
  fullName: "Generalised Anxiety Disorder-7",
  kind: "questionnaire",
  version: "1",
  language: "en",
  summary: "Anxiety symptoms, 7 items, about 2 minutes",
  instructions: "Over the last 2 weeks, how often have you been bothered by the following problems?",
  responseSets: { freq4: FREQ4 },
  items: items("gad7", [
    "Feeling nervous, anxious, or on edge",
    "Not being able to stop or control worrying",
    "Worrying too much about different things",
    "Trouble relaxing",
    "Being so restless that it is hard to sit still",
    "Becoming easily annoyed or irritable",
    "Feeling afraid as if something awful might happen"
  ], "freq4"),
  scoring: {
    method: "sum",
    max: 21,
    bands: [
      { min: 0, max: 4, label: "Minimal", severity: "none" },
      { min: 5, max: 9, label: "Mild", severity: "info" },
      { min: 10, max: 14, label: "Moderate", severity: "warn" },
      { min: 15, max: 21, label: "Severe", severity: "alert" }
    ]
  },
  licence: {
    name: "Pfizer: free to use, no permission required to reproduce, translate, display or distribute",
    status: "cleared",
    url: "https://www.phqscreeners.com/"
  },
  source: { name: "Built in", url: "https://www.phqscreeners.com/" }
};

var PCL5_DEF = {
  key: "pcl5",
  name: "PCL-5",
  fullName: "PTSD Checklist for DSM-5",
  kind: "questionnaire",
  version: "1",
  language: "en",
  summary: "PTSD symptoms, 20 items, about 6 minutes",
  instructions: "Below is a list of problems that people sometimes have in response to a very stressful experience. Please read each problem carefully and then choose how much you have been bothered by that problem in the past month.",
  responseSets: { pcl5: PCL5 },
  items: items("pcl5", [
    "Repeated, disturbing, and unwanted memories of the stressful experience?",
    "Repeated, disturbing dreams of the stressful experience?",
    "Suddenly feeling or acting as if the stressful experience were actually happening again (as if you were actually back there reliving it)?",
    "Feeling very upset when something reminded you of the stressful experience?",
    "Having strong physical reactions when something reminded you of the stressful experience (for example, heart pounding, trouble breathing, sweating)?",
    "Avoiding memories, thoughts, or feelings related to the stressful experience?",
    "Avoiding external reminders of the stressful experience (for example, people, places, conversations, activities, objects, or situations)?",
    "Trouble remembering important parts of the stressful experience?",
    "Having strong negative beliefs about yourself, other people, or the world (for example, having thoughts such as: I am bad, there is something seriously wrong with me, no one can be trusted, the world is completely dangerous)?",
    "Blaming yourself or someone else for the stressful experience or what happened after it?",
    "Having strong negative feelings such as fear, horror, anger, guilt, or shame?",
    "Loss of interest in activities that you used to enjoy?",
    "Feeling distant or cut off from other people?",
    "Trouble experiencing positive feelings (for example, being unable to feel happiness or have loving feelings for people close to you)?",
    "Irritable behavior, angry outbursts, or acting aggressively?",
    "Taking too many risks or doing things that could cause you harm?",
    "Being “superalert” or watchful or on guard?",
    "Feeling jumpy or easily startled?",
    "Having difficulty concentrating?",
    "Trouble falling or staying asleep?"
  ], "pcl5"),
  scoring: {
    method: "sum",
    max: 80,
    bands: [
      { min: 0, max: 30, label: "Below provisional cut-point", severity: "none" },
      { min: 31, max: 80, label: "At or above provisional cut-point (31–33)", severity: "warn" }
    ],
    subscales: [
      { id: "B", label: "Intrusion (B)", items: ids("pcl5", 1, 5), max: 20 },
      { id: "C", label: "Avoidance (C)", items: ids("pcl5", 6, 7), max: 8 },
      { id: "D", label: "Negative cognitions and mood (D)", items: ids("pcl5", 8, 14), max: 28 },
      { id: "E", label: "Arousal and reactivity (E)", items: ids("pcl5", 15, 20), max: 24 }
    ],
    note: "No official severity bands. A change of 10 points is suggested by the National Center for PTSD as clinically meaningful."
  },
  licence: {
    name: "US National Center for PTSD: public domain, not copyrighted",
    status: "cleared",
    url: "https://www.ptsd.va.gov/professional/assessment/adult-sr/ptsd-checklist.asp"
  },
  source: { name: "Built in", url: "https://www.ptsd.va.gov/" }
};

var WHO5_DEF = {
  key: "who5",
  name: "WHO-5",
  fullName: "WHO-5 Well-Being Index",
  kind: "questionnaire",
  version: "1",
  language: "en",
  summary: "Wellbeing, 5 items, about 1 minute",
  instructions: "Please indicate for each of the five statements which is closest to how you have been feeling over the last two weeks.",
  responseSets: { who5: WHO5 },
  items: items("who5", [
    "I have felt cheerful and in good spirits",
    "I have felt calm and relaxed",
    "I have felt active and vigorous",
    "I woke up feeling fresh and rested",
    "My daily life has been filled with things that interest me"
  ], "who5"),
  scoring: {
    method: "sum",
    multiplier: 4,
    max: 100,
    bands: [
      { min: 0, max: 28, label: "Very low wellbeing (≤28)", severity: "alert" },
      { min: 29, max: 50, label: "Low wellbeing (≤50)", severity: "warn" },
      { min: 51, max: 100, label: "Above screening threshold", severity: "none" }
    ]
  },
  licence: {
    name: "World Health Organization: CC BY-NC-SA 3.0 IGO. Confirm the non-commercial clause covers your practice's use. Do not use the WHO logo.",
    status: "review",
    url: "https://cdn.who.int/media/docs/default-source/mental-health/who-5_english-original4da539d6ed4b49389e3afe47cda2326a.pdf"
  },
  source: { name: "Built in", url: "https://www.who.int/" }
};

var BOX = {
  key: "box-breathing",
  name: "Box breathing",
  kind: "exercise",
  version: "1",
  language: "en",
  summary: "4 in, 4 hold, 4 out, 4 hold. 6 rounds.",
  exercise: {
    type: "breathing",
    rounds: 6,
    phases: [
      { label: "Breathe in", seconds: 4, expand: true },
      { label: "Hold", seconds: 4, expand: true },
      { label: "Breathe out", seconds: 4, expand: false },
      { label: "Hold", seconds: 4, expand: false }
    ]
  },
  items: [],
  licence: { name: "OpenWorks IT original content (AGPL-3.0)", status: "cleared" },
  source: { name: "Built in" }
};

var B478 = {
  key: "breathing-478",
  name: "4-7-8 breathing",
  kind: "exercise",
  version: "1",
  language: "en",
  summary: "4 in, 7 hold, 8 out. 4 rounds.",
  exercise: {
    type: "breathing",
    rounds: 4,
    phases: [
      { label: "Breathe in", seconds: 4, expand: true },
      { label: "Hold", seconds: 7, expand: true },
      { label: "Breathe out", seconds: 8, expand: false }
    ]
  },
  items: [],
  licence: { name: "OpenWorks IT original content (AGPL-3.0)", status: "cleared" },
  source: { name: "Built in" }
};

var PACED = {
  key: "paced-breathing",
  name: "Slow paced breathing",
  kind: "exercise",
  version: "1",
  language: "en",
  summary: "4 in, 6 out. About 3 minutes.",
  exercise: {
    type: "breathing",
    rounds: 18,
    phases: [
      { label: "Breathe in", seconds: 4, expand: true },
      { label: "Breathe out", seconds: 6, expand: false }
    ]
  },
  items: [],
  licence: { name: "OpenWorks IT original content (AGPL-3.0)", status: "cleared" },
  source: { name: "Built in" }
};

var GROUND = {
  key: "grounding-54321",
  name: "5-4-3-2-1 grounding",
  kind: "exercise",
  version: "1",
  language: "en",
  summary: "Notice the room through your senses. About 4 minutes.",
  exercise: {
    type: "steps",
    steps: [
      { title: "5 things you can see", prompt: "Look around slowly. Name five things you can see right now." },
      { title: "4 things you can feel", prompt: "The chair under you, your feet on the floor, your clothes. Name four." },
      { title: "3 things you can hear", prompt: "Listen past the obvious sounds. Name three." },
      { title: "2 things you can smell", prompt: "Or two smells you like, if nothing is nearby." },
      { title: "1 thing you can taste", prompt: "Or one thing you are grateful for right now." }
    ]
  },
  items: [],
  licence: { name: "OpenWorks IT original content (AGPL-3.0)", status: "cleared" },
  source: { name: "Built in" }
};

var THOUGHT = {
  key: "thought-record",
  name: "Thought record",
  kind: "exercise",
  version: "1",
  language: "en",
  summary: "Catch a thought, test it, reframe it. About 5 minutes.",
  exercise: {
    type: "steps",
    steps: [
      { title: "What happened?", prompt: "Briefly describe the situation: where, when, who." },
      { title: "What went through your mind?", prompt: "Write the thought as it came, in your own words." },
      { title: "What did you feel?", prompt: "Name the feeling and how strong it was, from 0 to 100." },
      { title: "What else could be true?", prompt: "Is there another way of looking at it? What would you tell a friend?" },
      { title: "How do you feel now?", prompt: "Name the feeling again, from 0 to 100." }
    ]
  },
  items: [],
  licence: { name: "OpenWorks IT original content (AGPL-3.0)", status: "cleared" },
  source: { name: "Built in" }
};

/*
 * Curated list of ReproSchema library activities relevant to an adult practice.
 * status: "public" = known free/public domain, "review" = check licence first,
 * "blocked" = marked copyright protected in the library itself.
 */
var REPROSCHEMA_CATALOG = [
  { activity: "PHQ-9", label: "PHQ-9", status: "public" },
  { activity: "PHQ-8", label: "PHQ-8 (PHQ-9 without item 9)", status: "public" },
  { activity: "PHQ-4", label: "PHQ-4 brief anxiety and depression", status: "public" },
  { activity: "PHQ_15", label: "PHQ-15 somatic symptoms", status: "public" },
  { activity: "GAD7", label: "GAD-7", status: "public" },
  { activity: "PC-PTSD-5", label: "PC-PTSD-5 primary care PTSD screen", status: "public" },
  { activity: "EPDS", label: "Edinburgh Postnatal Depression Scale", status: "review" },
  { activity: "PROMISGlobalHealth", label: "PROMIS Global Health", status: "review" },
  { activity: "WHODAS12", label: "WHODAS 2.0, 12 items", status: "review" },
  { activity: "MoodDisorderQuestionnaire", label: "Mood Disorder Questionnaire", status: "review" },
  { activity: "CageAid", label: "CAGE-AID", status: "review" },
  { activity: "SCS-SF", label: "Self-Compassion Scale, short form", status: "review" },
  { activity: "MAAS", label: "Mindful Attention Awareness Scale", status: "review" },
  { activity: "DAS", label: "Daily Affect Scale", status: "review" },
  { activity: "IAT", label: "Internet Addiction Test", status: "review" },
  { activity: "ICU_SR", label: "Inventory of Callous-Unemotional Traits (self-report)", status: "blocked" },
  { activity: "ICU_P", label: "Inventory of Callous-Unemotional Traits (parent)", status: "blocked" }
];

module.exports = {
  BUILTIN: [PHQ9, GAD7, PCL5_DEF, WHO5_DEF, BOX, B478, PACED, GROUND, THOUGHT],
  REPROSCHEMA_CATALOG: REPROSCHEMA_CATALOG
};
