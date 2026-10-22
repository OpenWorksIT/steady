/*
 * Steady - three fictional patients for the RADR research view (pure logic, ES2015).
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Made-up data, shaped after patterns the research describes (docs/RADR.md), so the practice can
 * see what RADR shows before real patients give it anything to show. They are not real people,
 * not a validated model of any illness, and must never be mixed into research results.
 *
 *   steady     : eight weeks of ordinary ups and downs. The control.
 *   decline    : four stable weeks, then four weeks of gradual low mood: sleep later and longer
 *                and more irregular (circadian phase delay; Lim et al. 2024), fewer steps, resting
 *                heart rate creeping up, check-ins and PHQ-9 drifting down.
 *   disruption : six stable weeks, then two weeks of acute disruption: short, erratic sleep
 *                (Littlewood et al. 2019; Bernert et al. 2017), resting heart rate up, restless
 *                then flat activity, anxious check-ins, PHQ-9 rising with item 9 answered.
 */

var DAY_MS = 86400000;
var DAYS = 56;

function rng(seed) {
  var a = seed >>> 0;
  return function () {
    a = (a + 0x6D2B79F5) >>> 0;
    var t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function gauss(r) {
  var u = 1 - r(), v = r();
  return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
}

function msToDay(ms) {
  var d = new Date(ms);
  var p = function (n) { return (n < 10 ? "0" : "") + n; };
  return d.getUTCFullYear() + "-" + p(d.getUTCMonth() + 1) + "-" + p(d.getUTCDate());
}

function clampRound(v, lo, hi) { return Math.round(Math.max(lo, Math.min(hi, v))); }
function scale(v) { return clampRound(v, 1, 5); }

var PROFILES = {
  steady: {
    label: "DEMO A · steady (research)",
    selfName: "Demo A",
    seed: 101,
    summary: "Eight ordinary weeks. The comparison case: RADR should stay low."
  },
  decline: {
    label: "DEMO B · gradual low mood (research)",
    selfName: "Demo B",
    seed: 202,
    summary: "Stable for four weeks, then four weeks of gradual slide: later, longer, irregular sleep, fewer steps, resting heart rate up, mood and energy down."
  },
  disruption: {
    label: "DEMO C · acute sleep disruption (research)",
    selfName: "Demo C",
    seed: 303,
    summary: "Stable for six weeks, then two weeks of short, erratic sleep, a higher resting heart rate, restless then flat activity and rising anxiety."
  }
};

/* How far into the change each day is, 0 (baseline) to 1. */
function progress(key, i) {
  if (key === "decline") return i < 28 ? 0 : (i - 27) / 28;
  if (key === "disruption") return i < 42 ? 0 : Math.min(1, (i - 41) / 6);
  return 0;
}

var NOTES = {
  steady: ["Good day at work.", "Bit tired but fine.", "Walked the dog, felt good.", "Busy day.", "Quiet evening.", "Saw friends."],
  declineEarly: ["Okay day.", "Fine, a bit flat.", "Normal day."],
  declineLate: ["Hard to get going today.", "Slept a lot, still tired.", "Didn't feel like going out.", "Everything feels like effort.", "Stayed in bed late again."],
  disruptionEarly: ["Good day.", "Fine.", "Productive."],
  disruptionLate: ["Couldn't sleep, mind racing.", "Up most of the night again.", "So on edge today.", "Can't switch off.", "Exhausted but wired."]
};

/**
 * todayMs: now. tzOffset: minutes east of UTC (Johannesburg 120).
 * Returns { key, label, selfName, summary, days:[{day, values}], checkins:[{at, mood, anxiety, sleep, energy, note}],
 *           questionnaires:[{at, key, answers}] } for each profile, the last day being yesterday.
 */
function generate(todayMs, tzOffset) {
  var tz = (typeof tzOffset === "number" ? tzOffset : 120) * 60000;
  var localToday = Math.floor((todayMs + tz) / DAY_MS) * DAY_MS; // local midnight, as a UTC instant + tz
  return Object.keys(PROFILES).map(function (key) {
    var p = PROFILES[key];
    var r = rng(p.seed);
    var days = [], checkins = [], questionnaires = [];
    for (var i = 0; i < DAYS; i++) {
      var dayStart = localToday - (DAYS - i) * DAY_MS; // local midnight of this day
      var day = msToDay(dayStart);
      var weekday = new Date(dayStart).getUTCDay(); // 0 Sunday
      var weekend = weekday === 0 || weekday === 6;
      var t = progress(key, i);

      // ---- watch
      var onset = -50 + (weekend ? 25 : 0) + 18 * gauss(r);   // minutes from midnight (negative = before)
      var sleep = 445 + (weekend ? 25 : 0) + 22 * gauss(r);
      var awake = 22 + 6 * gauss(r);
      var steps = (weekend ? 7200 : 9300) + 1300 * gauss(r);
      var rhr = 61 + 1.2 * gauss(r);
      if (key === "decline") {
        onset += 95 * t + 35 * t * gauss(r);
        sleep += 55 * t + 45 * t * gauss(r);
        awake += 18 * t;
        steps *= 1 - 0.5 * t;
        rhr += 5 * t;
      } else if (key === "disruption" && t > 0) {
        onset += 70 * t + 85 * t * gauss(r);
        sleep -= 150 * t - 40 * t * gauss(r);
        awake += 40 * t + 10 * gauss(r);
        rhr += 8 * t + 1.5 * gauss(r);
        // restless first, then flat
        steps = i < 48 ? steps * (1 + 0.35 * t) + 2500 * gauss(r) : steps * 0.45;
      }
      sleep = clampRound(sleep, 180, 720);
      awake = clampRound(awake, 5, 160);
      onset = clampRound(onset, -300, 300);
      var wake = onset + sleep + awake;
      var v = {
        sleep_min: sleep,
        sleep_onset: onset,
        sleep_wake: wake,
        sleep_deep: Math.round(sleep * (0.16 - 0.04 * t + 0.02 * gauss(r))),
        sleep_rem: Math.round(sleep * (0.22 - 0.03 * t + 0.02 * gauss(r))),
        sleep_awake: awake,
        rhr: clampRound(rhr, 40, 110),
        rhr_method: "sleep",
        hr_min: clampRound(rhr - 6 + gauss(r), 35, 100),
        hr_avg: clampRound(rhr + 14 + 2 * gauss(r) + (key === "disruption" ? 6 * t : 0), 45, 130),
        hr_max: clampRound(138 + 14 * gauss(r), 90, 190),
        steps: clampRound(steps, 300, 30000),
        spo2_avg: clampRound(96 + 0.8 * gauss(r), 90, 100)
      };
      v.sleep_light = Math.max(0, sleep - v.sleep_deep - v.sleep_rem);
      if (r() > 0.05) days.push({ day: day, values: v }); // about 1 night in 20 not worn

      // ---- check-in, most evenings
      if (r() < 0.86) {
        var mood = 3.9 + 0.5 * gauss(r), anxiety = 2.0 + 0.5 * gauss(r), sq = 3.9 + 0.5 * gauss(r), energy = 3.7 + 0.5 * gauss(r);
        if (key === "decline") { mood -= 1.9 * t; energy -= 1.8 * t; sq -= 1.2 * t; anxiety += 0.8 * t; }
        if (key === "disruption" && t > 0) { mood -= 1.3 * t + 0.6 * gauss(r); anxiety += 2.4 * t; sq -= 2.4 * t; energy -= 1.4 * t; }
        var pool = key === "steady" ? NOTES.steady
          : key === "decline" ? (t > 0.3 ? NOTES.declineLate : NOTES.declineEarly)
            : (t > 0 ? NOTES.disruptionLate : NOTES.disruptionEarly);
        checkins.push({
          at: dayStart - tz + (19 * 60 + Math.floor(r() * 150)) * 60000,
          mood: scale(mood), anxiety: scale(anxiety), sleep: scale(sq), energy: scale(energy),
          note: r() < 0.55 ? pool[Math.floor(r() * pool.length)] : ""
        });
      }

      // ---- weekly PHQ-9 and GAD-7, on Sundays
      if (weekday === 0) {
        var phq = 4, gad = 3, item9 = 0;
        if (key === "steady") { phq = 3 + Math.round(2 * r()); gad = 2 + Math.round(2 * r()); }
        if (key === "decline") { phq = Math.round(4 + 13 * t); gad = Math.round(3 + 5 * t); }
        if (key === "disruption") {
          phq = Math.round(5 + 11 * t); gad = Math.round(3 + 12 * t);
          if (t >= 1) item9 = 1;
        }
        var at = dayStart - tz + (10 * 60 + Math.floor(r() * 120)) * 60000;
        questionnaires.push({ at: at, key: "phq9", answers: spread("phq9", 9, phq, item9, r) });
        questionnaires.push({ at: at + 4 * 60000, key: "gad7", answers: spread("gad7", 7, gad, null, r) });
      }
    }
    return { key: key, label: p.label, selfName: p.selfName, summary: p.summary, days: days, checkins: checkins, questionnaires: questionnaires };
  });
}

/* Answers (0 to 3 each) adding up to total; fixedLast pins the last item (PHQ-9 item 9). */
function spread(prefix, n, total, fixedLast, r) {
  var a = {};
  var items = [];
  for (var i = 1; i <= n; i++) { a[prefix + "_" + i] = 0; items.push(prefix + "_" + i); }
  var left = total;
  var free = items;
  if (fixedLast !== null && fixedLast !== undefined) {
    a[items[n - 1]] = fixedLast;
    left -= fixedLast;
    free = items.slice(0, n - 1);
  }
  left = Math.max(0, Math.min(left, free.length * 3));
  var guard = 0;
  while (left > 0 && guard++ < 1000) {
    var k = free[Math.floor(r() * free.length)];
    if (a[k] < 3) { a[k]++; left--; }
  }
  return a;
}

module.exports = { PROFILES: PROFILES, DAYS: DAYS, generate: generate };
