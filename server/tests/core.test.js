// SPDX-License-Identifier: AGPL-3.0-or-later
// Run with: node --test server/tests
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const core = require("../pb_hooks/lib/core.js");
const { BUILTIN } = require("../pb_hooks/lib/instruments.js");

const byKey = Object.fromEntries(BUILTIN.map((d) => [d.key, d]));
const valid = (key) => {
  const r = core.validateInstrument(byKey[key]);
  assert.deepEqual(r.errors, [], key + " should validate");
  return r.def;
};
const answersAll = (def, v) => Object.fromEntries(def.items.map((i) => [i.id, typeof v === "function" ? v(i) : v]));

test("every built-in instrument validates", () => {
  for (const d of BUILTIN) {
    const r = core.validateInstrument(d);
    assert.deepEqual(r.errors, [], d.key);
  }
});

test("built-in keys are unique", () => {
  const keys = BUILTIN.map((d) => d.key);
  assert.equal(new Set(keys).size, keys.length);
});

test("PHQ-9 bands and item 9 flag", () => {
  const def = valid("phq9");
  assert.equal(def.items.length, 9);
  const zero = core.scoreAnswers(def, answersAll(def, 0));
  assert.equal(zero.total, 0);
  assert.equal(zero.band, "Minimal");
  assert.equal(zero.flags.length, 0);

  const a = answersAll(def, 2); // 18
  a.phq9_9 = 1; // 17
  const s = core.scoreAnswers(def, a);
  assert.equal(s.total, 17);
  assert.equal(s.max, 27);
  assert.equal(s.band, "Moderately severe");
  assert.equal(s.flags.length, 1);
  assert.match(s.flags[0].label, /Item 9/);
  assert.equal(s.severity, "alert");

  const top = core.scoreAnswers(def, answersAll(def, 3));
  assert.equal(top.total, 27);
  assert.equal(top.band, "Severe");
});

test("PHQ-9 boundaries", () => {
  const def = valid("phq9");
  const at = (n) => {
    const a = answersAll(def, 0);
    let left = n;
    for (const it of def.items.slice(0, 8)) { const v = Math.min(3, left); a[it.id] = v; left -= v; }
    return core.scoreAnswers(def, a);
  };
  assert.equal(at(4).band, "Minimal");
  assert.equal(at(5).band, "Mild");
  assert.equal(at(9).band, "Mild");
  assert.equal(at(10).band, "Moderate");
  assert.equal(at(14).band, "Moderate");
  assert.equal(at(15).band, "Moderately severe");
  assert.equal(at(19).band, "Moderately severe");
  assert.equal(at(20).band, "Severe");
});

test("GAD-7 scoring", () => {
  const def = valid("gad7");
  assert.equal(core.scoreAnswers(def, answersAll(def, 2)).total, 14);
  assert.equal(core.scoreAnswers(def, answersAll(def, 2)).band, "Moderate");
  assert.equal(core.scoreAnswers(def, answersAll(def, 3)).band, "Severe");
});

test("WHO-5 multiplies raw score by 4", () => {
  const def = valid("who5");
  assert.equal(def.items.length, 5);
  const s = core.scoreAnswers(def, answersAll(def, 2)); // raw 10 -> 40
  assert.equal(s.total, 40);
  assert.equal(s.band, "Low wellbeing (≤50)");
  assert.equal(core.scoreAnswers(def, answersAll(def, 5)).total, 100);
  assert.equal(core.scoreAnswers(def, answersAll(def, 1)).band, "Very low wellbeing (≤28)");
  assert.equal(byKey.who5.licence.status, "review", "WHO-5 stays under licence review until the practice confirms");
});

test("PCL-5 total, cut-point and clusters", () => {
  const def = valid("pcl5");
  assert.equal(def.items.length, 20);
  const a = answersAll(def, 0);
  for (let i = 1; i <= 5; i++) a["pcl5_" + i] = 4; // B = 20
  a.pcl5_6 = 3; a.pcl5_7 = 3;                         // C = 6
  a.pcl5_8 = 1;                                        // D = 1
  a.pcl5_20 = 4;                                       // E = 4
  const s = core.scoreAnswers(def, a);
  assert.equal(s.total, 31);
  assert.match(s.band, /At or above/);
  const sub = Object.fromEntries(s.subscales.map((x) => [x.id, x.total]));
  assert.deepEqual(sub, { B: 20, C: 6, D: 1, E: 4 });
  assert.equal(core.scoreAnswers(def, answersAll(def, 1)).band, "Below provisional cut-point");
});

test("answers outside the options are rejected", () => {
  const def = valid("phq9");
  const a = answersAll(def, 0);
  a.phq9_3 = 7;
  const r = core.validateAnswers(def, a);
  assert.equal(r.ok, false);
  assert.match(r.errors[0], /phq9_3/);
  delete a.phq9_3;
  assert.equal(core.validateAnswers(def, a).ok, false, "missing required answer");
  assert.equal(core.validateAnswers(def, "nope").ok, false);
});

test("validateAnswers drops unknown keys", () => {
  const def = valid("gad7");
  const a = answersAll(def, 1);
  a.__proto_injection = 3;
  const r = core.validateAnswers(def, a);
  assert.equal(r.ok, true);
  assert.equal(Object.keys(r.answers).length, 7);
});

test("instrument validation catches common mistakes", () => {
  const r = core.validateInstrument({
    key: "Bad Key!", name: "", kind: "questionnaire",
    items: [{ id: "a", text: "Q" }, { id: "a", text: "" }],
    scoring: { bands: [{ min: 5, max: 1 }], itemFlags: [{ item: "zz", op: "!", value: 1 }] }
  });
  assert.equal(r.ok, false);
  const joined = r.errors.join("\n");
  assert.match(joined, /key must/);
  assert.match(joined, /name is required/);
  assert.match(joined, /used twice/);
  assert.match(joined, /text is required/);
  assert.match(joined, /needs options/);
  assert.match(joined, /min <= max/);
  assert.match(joined, /unknown item 'zz'/);
});

test("a clinician-built questionnaire validates and scores", () => {
  const r = core.validateInstrument({
    key: "sleep-diary", name: "Sleep diary", kind: "questionnaire",
    responseSets: { q: [{ label: "No", value: 0 }, { label: "Yes", value: 1 }] },
    items: [
      { id: "woke", text: "Did you wake in the night?", responseSet: "q" },
      { id: "hours", text: "Hours slept", type: "number", min: 0, max: 14 },
      { id: "notes", text: "Anything else?", type: "text", required: false }
    ],
    scoring: { method: "sum", items: ["woke"], bands: [{ min: 1, max: 1, label: "Woke", severity: "info" }] }
  });
  assert.deepEqual(r.errors, []);
  const v = core.validateAnswers(r.def, { woke: 1, hours: 6.5 });
  assert.equal(v.ok, true);
  assert.equal(core.scoreAnswers(r.def, v.answers).band, "Woke");
  assert.equal(r.def.licence.status, "review", "unknown licence defaults to review");
});

test("exercise definitions and results", () => {
  const box = valid("box-breathing");
  assert.deepEqual(core.validateExerciseResult(box, { rounds: 99, seconds: 96.4 }), { rounds: 6, seconds: 96 });
  const tr = valid("thought-record");
  const out = core.validateExerciseResult(tr, { answers: ["a", "b"] });
  assert.equal(out.answers.length, 5);
  assert.equal(out.answers[2], "");
  const bad = core.validateInstrument({ key: "x1", name: "X", kind: "exercise", exercise: { type: "breathing", phases: [{ label: "in", seconds: 99 }] } });
  assert.equal(bad.ok, false);
});

test("check-in validation", () => {
  assert.equal(core.validateCheckin({ mood: 3, anxiety: 2, sleep: 4, energy: 5, note: "  ok  " }).value.note, "ok");
  assert.equal(core.validateCheckin({ mood: 0, anxiety: 2, sleep: 4, energy: 5 }).ok, false);
  assert.equal(core.validateCheckin({ mood: 2.5, anxiety: 2, sleep: 4, energy: 5 }).ok, false);
  assert.equal(core.validateCheckin({}).errors.length, 4);
  const long = core.validateCheckin({ mood: 1, anxiety: 1, sleep: 1, energy: 1, note: "x".repeat(5000) });
  assert.equal(long.value.note.length, 1000);
});

test("daily series averages by day and leaves gaps empty", () => {
  const now = Date.UTC(2026, 9, 14, 12);
  const day = core.DAY;
  const cs = [
    { ts: now - 1000, mood: 2 },
    { ts: now - 2000, mood: 4 },
    { ts: now - 2 * day, mood: 5 }
  ];
  const s = core.dailySeries(cs, "mood", now, 4, 0);
  assert.deepEqual(s, [null, 5, null, 3]);
  // SAST (UTC+2): a check-in at 23:30 UTC belongs to the next local day
  const late = Date.UTC(2026, 9, 13, 23, 30);
  const s2 = core.dailySeries([{ ts: late, mood: 1 }], "mood", now, 2, 120);
  assert.deepEqual(s2, [null, 1]);
});

test("review flags", () => {
  const now = Date.UTC(2026, 9, 14, 12);
  const day = core.DAY;
  const phq = valid("phq9");
  const a = answersAll(phq, 2); a.phq9_9 = 1;
  const score = core.scoreAnswers(phq, a);
  const flags = core.reviewFlags(
    [{ ts: now - day, mood: 2 }, { ts: now - 2 * day, mood: 1 }, { ts: now - 3 * day, mood: 2 }],
    [
      { status: "done", completedAt: now - day, name: "PHQ-9", score },
      { status: "pending", assignedAt: now - day, name: "GAD-7" },
      { status: "pending", assignedAt: now, availableFrom: now + day, name: "GAD-7" }
    ],
    now
  );
  const labels = flags.map((f) => f.label);
  assert.equal(flags[0].severity, "alert");
  assert.ok(labels.includes("PHQ-9: Item 9 endorsed: review"));
  assert.ok(labels.includes("PHQ-9 17: Moderately severe"));
  assert.ok(labels.includes("Low mood in the last 3 check-ins"));
  assert.ok(labels.includes("1 waiting"), "future repeats are not counted");

  const quiet = core.reviewFlags([{ ts: now - 5 * day, mood: 4 }], [], now);
  assert.deepEqual(quiet.map((f) => f.label), ["No check-in for 5 days"]);
  const old = core.reviewFlags([{ ts: now, mood: 4 }], [{ status: "done", completedAt: now - 30 * day, name: "PHQ-9", score }], now);
  assert.equal(old.length, 0, "results older than 14 days don't flag");
});

test("repeat scheduling", () => {
  const t = Date.UTC(2026, 9, 14, 15);
  assert.equal(core.nextAvailable("daily", t, 120), Date.UTC(2026, 9, 14, 22));
  assert.equal(core.nextAvailable("weekly", t, 0), Date.UTC(2026, 9, 21));
  assert.equal(core.nextAvailable("once", t, 0), null);
});

test("invite codes", () => {
  assert.equal(core.formatCode("abcd2345"), "ABCD-2345");
  assert.equal(core.normaliseCode(" abcd-2345 "), "ABCD2345");
  assert.ok(!/[01OI]/.test(core.CODE_ALPHABET), "no ambiguous characters");
});

test("FHIR Questionnaire import", () => {
  const q = {
    resourceType: "Questionnaire", name: "MiniPHQ", title: "Mini PHQ", status: "active",
    copyright: "Example only",
    item: [{
      linkId: "g1", type: "group", item: [
        { linkId: "q1", text: "Little interest?", type: "choice", required: true, answerOption: [
          { valueCoding: { code: "LA6568-5", display: "Not at all" }, extension: [{ url: "http://hl7.org/fhir/StructureDefinition/ordinalValue", valueDecimal: 0 }] },
          { valueCoding: { code: "LA6569-3", display: "Several days" }, extension: [{ url: "http://hl7.org/fhir/StructureDefinition/ordinalValue", valueDecimal: 1 }] }
        ] },
        { linkId: "q2", text: "Comments", type: "string" },
        { linkId: "d1", text: "Thanks", type: "display" }
      ]
    }]
  };
  const def = core.fromFhirQuestionnaire(q);
  const r = core.validateInstrument(def);
  assert.deepEqual(r.errors, []);
  assert.equal(r.def.items.length, 2);
  assert.deepEqual(r.def.items[0].options.map((o) => o.value), [0, 1]);
  assert.equal(r.def.items[1].type, "text");
  assert.equal(r.def.licence.status, "review");
  assert.throws(() => core.fromFhirQuestionnaire({ resourceType: "Patient" }));
});

function reproLoader(activity) {
  const base = path.join(__dirname, "fixtures", "reproschema", activity);
  return (rel) => {
    const p = path.join(base, rel);
    if (!p.startsWith(base)) throw new Error("path escape");
    return JSON.parse(fs.readFileSync(p, "utf8"));
  };
}

test("ReproSchema import: PHQ-9 from the real library files", () => {
  const load = reproLoader("PHQ-9");
  const def = core.fromReproSchema("PHQ-9", load("PHQ9_schema"), load, "en");
  const r = core.validateInstrument(def);
  assert.deepEqual(r.errors, []);
  assert.equal(r.def.items.length, 10, "9 items plus the conditional difficulty item");
  assert.equal(r.def.items[0].text, "Little interest or pleasure in doing things");
  assert.deepEqual(r.def.scoring.items.length, 9, "total score computed from the 9 symptom items");
  assert.ok(r.def.items[9].showIf, "item 10 only shows when any symptom is endorsed");
  const answers = Object.fromEntries(r.def.items.slice(0, 9).map((i) => [i.id, 0]));
  const v = core.validateAnswers(r.def, answers);
  assert.equal(v.ok, true, "item 10 is hidden when all answers are 0: " + v.errors.join(","));
  answers[r.def.items[0].id] = 1;
  assert.equal(core.validateAnswers(r.def, answers).ok, false, "item 10 becomes required once visible");
  assert.equal(r.def.licence.status, "review");
});

test("ReproSchema import: GAD-7 and conditional PC-PTSD-5", () => {
  const g = reproLoader("GAD7");
  const gad = core.validateInstrument(core.fromReproSchema("GAD7", g("GAD7_schema"), g, "en"));
  assert.deepEqual(gad.errors, []);
  assert.ok(gad.def.items.length >= 7);

  const p = reproLoader("PC-PTSD-5");
  const pc = core.validateInstrument(core.fromReproSchema("PC-PTSD-5", p("PC-PTSD-5_schema"), p, "en"));
  assert.deepEqual(pc.errors, []);
  assert.equal(pc.def.items.length, 6);
  assert.deepEqual(pc.def.items[1].showIf, { anyOf: [{ item: "ptsd_1", op: "=", value: 1 }] });
  assert.equal(core.validateAnswers(pc.def, { ptsd_1: 0 }).ok, true, "no event: nothing else asked");
  const yes = core.validateAnswers(pc.def, { ptsd_1: 1, ptsd_2: 1, ptsd_3: 0, ptsd_4: 1, ptsd_5: 1, ptsd_6: 0 });
  assert.equal(yes.ok, true, yes.errors.join(","));
  assert.equal(core.scoreAnswers(pc.def, yes.answers).total, 3);
});

test("the documented examples are valid", () => {
  const dir = path.join(__dirname, "..", "..", "docs", "examples");
  const steady = JSON.parse(fs.readFileSync(path.join(dir, "session-feedback.steady.json"), "utf8"));
  const r = core.validateInstrument(steady);
  assert.deepEqual(r.errors, []);
  assert.equal(core.validateAnswers(r.def, { heard: 2, goals: 2, worse: 0 }).ok, true);
  assert.equal(core.validateAnswers(r.def, { heard: 2, goals: 2, worse: 1 }).ok, false, "follow-up becomes required");
  const s = core.scoreAnswers(r.def, { heard: 0, goals: 1, worse: 1, what: "x" });
  assert.equal(s.band, "Low alliance");
  assert.equal(s.flags[0].label, "Felt worse after session");

  const fhir = JSON.parse(fs.readFileSync(path.join(dir, "mini-wellbeing.fhir.json"), "utf8"));
  const f = core.validateInstrument(core.fromFhirQuestionnaire(fhir));
  assert.deepEqual(f.errors, []);
  assert.equal(f.def.items.length, 3);
});
