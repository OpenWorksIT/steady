/*
 * Steady - RADR, the Research Amon Dîn Rating (pure logic, ES2015, no PocketBase globals).
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * How far a patient's watch data and check-ins are from their own normal, to improve care. Not a
 * risk score, prediction or diagnosis, and not watched around the clock. It follows what the
 * research on passive watch data reports: that single measures say little on their own, and that
 * change shows when several domains move away from the person's own normal at the same time, and
 * alongside what the person reports. In the psychologist's list it only orders patients (an
 * ordering of data, never an alert), below answers waiting for review (lib/core.js attention).
 *
 * Every number can be explained (explain(): the plain-words reasoning and the days and values
 * behind it), and each domain away from usual is a flag the psychologist can mark as reviewed
 * (flags(): a stable key per run of days away from usual).
 *
 * Method (docs/RADR.md has the sources). A day is rated once the baseline has 14 days of data.
 *  1. Each measure is smoothed over 3 days, then compared with the person's own baseline: the 28
 *     days that end a week before the day (so a change building over the last week doesn't hide
 *     inside its own baseline). Distance from normal = robust z-score (median and MAD).
 *  2. Measures are grouped into four domains, each scored 0 to 4 in the direction the research
 *     links to decline:
 *       sleep     : duration away from usual (shorter or longer), and night-to-night variability
 *                   of sleep onset and waking (Bernert et al. 2017)
 *       circadian : the sleep midpoint shifting earlier or later (Lim et al. 2024)
 *       activity  : fewer steps than usual
 *       cardiac   : resting heart rate above usual; heart rate variability below usual, if the
 *                   watch provides it (Um et al. 2025)
 *  3. Watch index = mean of the domain scores (at least 2 domains). Convergence = how many
 *     domains are at least 1.5 from normal on the same day.
 *  4. Self-report score: the daily check-in (lower mood and energy, more anxiety, worse sleep),
 *     scored the same way. Combined index = mean of watch index and self-report score.
 *  5. Concordance: rank correlation between the watch index and the self-report score, with the
 *     watch leading by 0 to 3 days: does passive data add anything over what the person tells
 *     us, and does it move first?
 */

var DAY_MS = 86400000;
var BASELINE_DAYS = 28;
var BASELINE_GAP = 7;
var BASELINE_MIN = 14;
var SMOOTH = 3;
var NOTABLE = 1.5;
var CAP = 4;
var VERSION = "radr-1";

/* Smallest spread used for each measure, so a very regular baseline doesn't turn tiny changes into
   large scores. In the measure's own units. */
var FLOOR = {
  sleep_min: 20, sleep_var: 12, midpoint: 20, steps: 800, rhr: 1.5, hrv: 3,
  mood: 0.35, anxiety: 0.35, energy: 0.35, sleepq: 0.35
};

var DOMAINS = ["sleep", "circadian", "activity", "cardiac"];
var LABELS = {
  sleep: "Sleep", circadian: "Body clock", activity: "Activity", cardiac: "Heart", self: "Check-ins"
};

function dayToMs(day) { return Date.UTC(+day.slice(0, 4), +day.slice(5, 7) - 1, +day.slice(8, 10)); }
function msToDay(ms) {
  var d = new Date(ms);
  var p = function (n) { return (n < 10 ? "0" : "") + n; };
  return d.getUTCFullYear() + "-" + p(d.getUTCMonth() + 1) + "-" + p(d.getUTCDate());
}
var ADD_CACHE = {};
var ADD_SIZE = 0;
/** day + n days. Cached: the rating asks for the same few hundred dates many thousands of times. */
function addDays(day, n) {
  var k = day + "|" + n;
  var v = ADD_CACHE[k];
  if (v === undefined) {
    v = msToDay(dayToMs(day) + n * DAY_MS);
    if (++ADD_SIZE > 50000) { ADD_CACHE = {}; ADD_SIZE = 1; }
    ADD_CACHE[k] = v;
  }
  return v;
}

/** fn(day), worked out once per day. */
function memo(fn) {
  var cache = {};
  return function (day) {
    if (!(day in cache)) cache[day] = fn(day);
    return cache[day];
  };
}
function isNum(v) { return typeof v === "number" && isFinite(v); }
function r2(n) { return n === null ? null : Math.round(n * 100) / 100; }

function median(xs) {
  var s = xs.slice().sort(function (a, b) { return a - b; });
  var n = s.length;
  if (!n) return null;
  return n % 2 ? s[(n - 1) / 2] : (s[n / 2 - 1] + s[n / 2]) / 2;
}

function mean(xs) {
  if (!xs.length) return null;
  return xs.reduce(function (a, b) { return a + b; }, 0) / xs.length;
}

function sd(xs) {
  if (xs.length < 2) return null;
  var m = mean(xs);
  return Math.sqrt(xs.reduce(function (a, b) { return a + (b - m) * (b - m); }, 0) / (xs.length - 1));
}

/** Robust z: (x - median) / (1.4826 * MAD), with a floor on the spread. */
function robustZ(x, base, floor) {
  if (!isNum(x) || base.length < BASELINE_MIN) return null;
  var m = median(base);
  var mad = median(base.map(function (b) { return Math.abs(b - m); }));
  var spread = Math.max(1.4826 * mad, floor || 0);
  if (!(spread > 0)) return null;
  return (x - m) / spread;
}

function clip(v) { return v === null ? null : Math.max(0, Math.min(CAP, v)); }

/* ---------- daily raw measures ---------- */

/** Minutes from midnight of the sleep midpoint, from onset (may be negative: before midnight) and wake. */
function midpoint(v) {
  if (!isNum(v.sleep_onset) || !isNum(v.sleep_wake)) return null;
  var onset = v.sleep_onset, wake = v.sleep_wake;
  if (wake < onset) wake += 1440;
  return (onset + wake) / 2;
}

/**
 * byDay: { "YYYY-MM-DD": { sleep_min, sleep_onset, sleep_wake, steps, rhr, hrv_rmssd, ... } }
 * checkins: { "YYYY-MM-DD": { mood, anxiety, sleep, energy } } (daily means, 1 to 5)
 * Returns raw daily series keyed by measure.
 */
function rawSeries(byDay, checkins) {
  var s = { sleep_min: {}, onset: {}, wake: {}, midpoint: {}, steps: {}, rhr: {}, hrv: {}, mood: {}, anxiety: {}, energy: {}, sleepq: {} };
  Object.keys(byDay || {}).forEach(function (d) {
    var v = byDay[d] || {};
    if (isNum(v.sleep_min) && v.sleep_min > 0) s.sleep_min[d] = v.sleep_min;
    if (isNum(v.sleep_onset)) s.onset[d] = v.sleep_onset;
    if (isNum(v.sleep_wake)) s.wake[d] = v.sleep_wake;
    var mp = midpoint(v);
    if (mp !== null) s.midpoint[d] = mp;
    if (isNum(v.steps)) s.steps[d] = v.steps;
    if (isNum(v.rhr)) s.rhr[d] = v.rhr;
    if (isNum(v.hrv_rmssd)) s.hrv[d] = v.hrv_rmssd;
  });
  Object.keys(checkins || {}).forEach(function (d) {
    var c = checkins[d] || {};
    if (isNum(c.mood)) s.mood[d] = c.mood;
    if (isNum(c.anxiety)) s.anxiety[d] = c.anxiety;
    if (isNum(c.energy)) s.energy[d] = c.energy;
    if (isNum(c.sleep)) s.sleepq[d] = c.sleep;
  });
  return s;
}

/** Mean of the last SMOOTH days ending on day (at least 2 values), else null. */
function smoothed(series, day) {
  var xs = [];
  for (var i = 0; i < SMOOTH; i++) {
    var v = series[addDays(day, -i)];
    if (isNum(v)) xs.push(v);
  }
  return xs.length >= 2 ? mean(xs) : null;
}

/** Night-to-night variability: SD of sleep onset + SD of waking over the 7 nights ending on day. */
function variability(s, day) {
  var on = [], wk = [];
  for (var i = 0; i < 7; i++) {
    var d = addDays(day, -i);
    if (isNum(s.onset[d])) on.push(s.onset[d]);
    if (isNum(s.wake[d])) wk.push(s.wake[d]);
  }
  if (on.length < 4 || wk.length < 4) return null;
  return sd(on) + sd(wk);
}

/** A measure on day, and its baseline values (same measure on the baseline days). */
function compare(fn, day, floor) {
  var x = fn(day);
  var base = [];
  for (var i = BASELINE_GAP + 1; i <= BASELINE_GAP + BASELINE_DAYS; i++) {
    var b = fn(addDays(day, -i));
    if (isNum(b)) base.push(b);
  }
  return { value: x, z: robustZ(x, base, floor), n: base.length, usual: base.length >= BASELINE_MIN ? median(base) : null };
}

/* ---------- the rating ---------- */

/** The daily measures, each worked out once per day however often the baselines ask. */
function measures(s) {
  var sm = function (series) { return memo(function (d) { return smoothed(series, d); }); };
  return {
    sleep_min: sm(s.sleep_min), sleep_var: memo(function (d) { return variability(s, d); }), midpoint: sm(s.midpoint),
    steps: sm(s.steps), rhr: sm(s.rhr), hrv: sm(s.hrv),
    mood: sm(s.mood), anxiety: sm(s.anxiety), energy: sm(s.energy), sleepq: sm(s.sleepq)
  };
}

function dayRating(s, day, m, exclude) {
  m = m || measures(s);
  exclude = exclude || [];
  var f = {};
  Object.keys(m).forEach(function (k) { f[k] = compare(m[k], day, FLOOR[k]); });

  var z = function (k) { return f[k].z; };
  var maxOf = function (xs) {
    var v = xs.filter(function (x) { return x !== null; });
    return v.length ? Math.max.apply(null, v) : null;
  };
  var pos = function (v) { return v === null ? null : Math.max(0, v); };
  var abs = function (v) { return v === null ? null : Math.abs(v); };
  var neg = function (v) { return v === null ? null : Math.max(0, -v); };

  var domains = {
    sleep: clip(maxOf([abs(z("sleep_min")), pos(z("sleep_var"))])),
    circadian: clip(abs(z("midpoint"))),
    activity: clip(neg(z("steps"))),
    cardiac: clip(maxOf([pos(z("rhr")), neg(z("hrv"))]))
  };
  // domains the psychologist switched off for this patient (e.g. sleep for a shift worker):
  // still collected and shown, just not counted
  exclude.forEach(function (k) { if (domains.hasOwnProperty(k)) domains[k] = null; });
  var present = DOMAINS.filter(function (k) { return domains[k] !== null; });
  var watch = present.length >= 2 ? mean(present.map(function (k) { return domains[k]; })) : null;
  var awayList = present.filter(function (k) { return domains[k] >= NOTABLE; });
  var convergent = awayList.length;

  var selfParts = [neg(z("mood")), pos(z("anxiety")), neg(z("energy")), neg(z("sleepq"))].filter(function (v) { return v !== null; });
  var self = selfParts.length >= 2 ? clip(mean(selfParts)) : null;
  var combined = watch !== null && self !== null ? (watch + self) / 2 : null;

  var features = {};
  // value, the person's usual (baseline median) and how far from it: for the day breakdown
  Object.keys(f).forEach(function (k) {
    features[k] = { value: f[k].value === null ? null : r2(f[k].value), z: r2(f[k].z), usual: f[k].usual === null || f[k].usual === undefined ? null : r2(f[k].usual) };
  });
  var dom = {};
  DOMAINS.forEach(function (k) { dom[k] = r2(domains[k]); });
  // the direction the circadian domain moved: + later (delay), - earlier (advance)
  var shift = f.midpoint.z === null ? null : (f.midpoint.z > 0 ? "later" : "earlier");
  return {
    day: day,
    domains: dom,
    watch: r2(watch),
    self: r2(self),
    combined: r2(combined),
    convergent: convergent,
    // the domains counted in convergent (at NOTABLE or more, before rounding)
    away: awayList,
    shift: shift,
    features: features,
    baselineDays: Math.max(f.sleep_min.n, f.steps.n, f.rhr.n)
  };
}

/* Spearman rank correlation of paired values. */
function ranks(xs) {
  var idx = xs.map(function (v, i) { return [v, i]; }).sort(function (a, b) { return a[0] - b[0]; });
  var r = new Array(xs.length);
  var i = 0;
  while (i < idx.length) {
    var j = i;
    while (j + 1 < idx.length && idx[j + 1][0] === idx[i][0]) j++;
    var rank = (i + j) / 2 + 1;
    for (var k = i; k <= j; k++) r[idx[k][1]] = rank;
    i = j + 1;
  }
  return r;
}

function spearman(a, b) {
  if (a.length < 10) return null;
  var ra = ranks(a), rb = ranks(b);
  var ma = mean(ra), mb = mean(rb);
  var num = 0, da = 0, db = 0;
  for (var i = 0; i < ra.length; i++) {
    num += (ra[i] - ma) * (rb[i] - mb);
    da += (ra[i] - ma) * (ra[i] - ma);
    db += (rb[i] - mb) * (rb[i] - mb);
  }
  if (!(da > 0) || !(db > 0)) return null;
  return num / Math.sqrt(da * db);
}

/** Watch index on day d against the self-report score on day d + lag. */
function concordance(rows) {
  var byDay = {};
  rows.forEach(function (r) { byDay[r.day] = r; });
  var out = [];
  for (var lag = 0; lag <= 3; lag++) {
    var a = [], b = [];
    rows.forEach(function (r) {
      var later = byDay[addDays(r.day, lag)];
      if (r.watch !== null && later && later.self !== null) { a.push(r.watch); b.push(later.self); }
    });
    out.push({ lag: lag, n: a.length, rho: r2(spearman(a, b)) });
  }
  return out;
}

/**
 * The rating for each day from `from` to `to` (YYYY-MM-DD). byDay and checkins must reach back
 * BASELINE_GAP + BASELINE_DAYS + 7 days before `from` for the first days to have a baseline.
 */
function rate(byDay, checkins, from, to, opts) {
  opts = opts || {};
  var exclude = (opts.exclude || []).filter(function (k) { return DOMAINS.indexOf(k) >= 0; });
  var s = rawSeries(byDay, checkins);
  var m = measures(s);
  var rows = [];
  for (var d = from; d <= to; d = addDays(d, 1)) rows.push(dayRating(s, d, m, exclude));
  var rated = rows.filter(function (r) { return r.watch !== null; });
  var last = rated.length ? rated[rated.length - 1] : null;
  return {
    version: VERSION,
    from: from,
    to: to,
    days: rows,
    latest: last,
    concordance: concordance(rows),
    wearDays: Object.keys(byDay || {}).filter(function (d) { return d >= from && d <= to; }).length,
    checkinDays: Object.keys(checkins || {}).filter(function (d) { return d >= from && d <= to; }).length,
    excluded: exclude,
    method: {
      baselineDays: BASELINE_DAYS, baselineGap: BASELINE_GAP, baselineMin: BASELINE_MIN,
      smoothDays: SMOOTH, notable: NOTABLE, cap: CAP, domains: DOMAINS, labels: LABELS
    }
  };
}

/**
 * Where RADR puts a patient in their psychologist's list, from the latest day kept on their
 * account (radr_data.js refreshLatest). An ordering of data, never an alert or a risk:
 *   "none"     nothing away from usual on a recent day (a day older than 3 days counts for nothing)
 *   "reviewed" domains away from usual, every one of them marked as reviewed: no higher in the list
 *   "away"     domains away from usual not yet reviewed; latest.convergent says how many
 * lib/core.js attention() puts RADR below every answer waiting for review.
 */
function level(latest, today) {
  if (!latest || latest.watch === null || latest.watch === undefined) return "none";
  if (today && addDays(latest.day, 3) < today) return "none";
  if (!(latest.convergent > 0)) return "none";
  var fl = latest.flags;
  if (Array.isArray(fl) && fl.length && fl.every(function (f) { return f && f.reviewed; })) return "reviewed";
  return "away";
}

/* ---------- flags: what the psychologist can mark as reviewed ---------- */

/* Days without a value for a domain (the watch wasn't worn) don't end a run of days away from
   usual, unless there are more than this many in a row. */
var GAP_MAX = 7;

/**
 * The flags on the latest rated day of rows (rate().days, oldest first): one for each counted
 * domain away from usual (NOTABLE or more). key "radr:<domain>:<since>" stays the same while that
 * run of days away from usual lasts, so a review of it holds until something new appears: another
 * domain moving away, or this one coming back to usual and moving away again.
 * open: the run reaches the first of rows, so since may be earlier (work it out on more days).
 */
function flags(rows) {
  var idx = -1;
  for (var i = (rows || []).length - 1; i >= 0; i--) {
    if (rows[i].watch !== null && rows[i].watch !== undefined) { idx = i; break; }
  }
  if (idx < 0) return [];
  var last = rows[idx];
  var out = [];
  (last.away || []).forEach(function (k) {
    var since = last.day, gap = 0, open = true;
    for (var j = idx - 1; j >= 0; j--) {
      var v = rows[j].domains ? rows[j].domains[k] : null;
      if (v === null || v === undefined) {
        if (++gap > GAP_MAX) { open = false; break; }
        continue;
      }
      if ((rows[j].away || []).indexOf(k) < 0) { open = false; break; }
      gap = 0;
      since = rows[j].day;
    }
    out.push({ key: "radr:" + k + ":" + since, domain: k, label: LABELS[k] + " away from usual", since: since, day: last.day, score: last.domains[k], open: open });
  });
  return out;
}

/* ---------- one day explained: plain words, and the days and values behind them ---------- */

/* Each measure, its domain, and the direction counted (the direction the research links to
   decline). Check-ins ("self") are scored the same way but kept beside the watch. */
var MEASURES = {
  sleep_min: { label: "Sleep length", domain: "sleep", dir: "either", per: "nights" },
  sleep_var: { label: "Sleep irregularity", domain: "sleep", dir: "up", per: "nights" },
  midpoint: { label: "Middle of sleep", domain: "circadian", dir: "either", per: "nights" },
  steps: { label: "Steps", domain: "activity", dir: "down", per: "days" },
  rhr: { label: "Resting heart rate", domain: "cardiac", dir: "up", per: "days" },
  hrv: { label: "Heart rate variability", domain: "cardiac", dir: "down", per: "days" },
  mood: { label: "Mood", domain: "self", dir: "down", per: "days" },
  anxiety: { label: "Anxiety", domain: "self", dir: "up", per: "days" },
  energy: { label: "Energy", domain: "self", dir: "down", per: "days" },
  sleepq: { label: "Sleep (their rating)", domain: "self", dir: "down", per: "days" }
};
var DOMAIN_MEASURES = { sleep: ["sleep_min", "sleep_var"], circadian: ["midpoint"], activity: ["steps"], cardiac: ["rhr", "hrv"] };
var SELF_MEASURES = ["mood", "anxiety", "energy", "sleepq"];

/* Which way counts, in words. */
var COUNTED = {
  sleep_min: "Shorter or longer than usual both count.",
  sleep_var: "Only more irregular than usual counts.",
  midpoint: "Earlier or later than usual both count.",
  steps: "Only fewer steps than usual count.",
  rhr: "Only a higher resting heart rate than usual counts.",
  hrv: "Only lower than usual counts.",
  mood: "Only lower mood than usual counts.",
  anxiety: "Only more anxiety than usual counts.",
  energy: "Only lower energy than usual counts.",
  sleepq: "Only worse sleep than usual counts."
};

/* Why each measure is in RADR (docs/RADR.md has the sources). */
var WHY = {
  sleep_min: "Short and poor sleep came before suicidal thoughts the next day in one study (Littlewood et al. 2019).",
  sleep_var: "Nights that varied in when someone fell asleep and woke came before more suicidal thoughts over three weeks, apart from depression (Bernert et al. 2017).",
  midpoint: "Day-to-day shifts in the body clock were the strongest sign before mood episodes in one study, with later sleep before depressive episodes (Lim et al. 2024).",
  steps: "Activity added to other measures in picking up depression, though on its own it says little (Rykov et al. 2021).",
  rhr: "Watch heart measures, read with mood ratings, carried signal in one study (Um et al. 2025).",
  hrv: "Heart rate variability was among the strongest watch measures in one study (Um et al. 2025).",
  mood: "What they reported in their check-ins. Studies found asking does at least as well as watch data (Büscher et al. 2024).",
  anxiety: "What they reported in their check-ins. Studies found asking does at least as well as watch data (Büscher et al. 2024).",
  energy: "What they reported in their check-ins. Studies found asking does at least as well as watch data (Büscher et al. 2024).",
  sleepq: "What they reported in their check-ins. Studies found asking does at least as well as watch data (Büscher et al. 2024)."
};

/* Words for a value above / below usual. */
var UP_DOWN = {
  sleep_min: ["longer", "shorter"], sleep_var: ["more irregular", "more regular"], midpoint: ["later", "earlier"],
  steps: ["more", "fewer"], rhr: ["higher", "lower"], hrv: ["higher", "lower"],
  mood: ["higher", "lower"], anxiety: ["higher", "lower"], energy: ["higher", "lower"], sleepq: ["better", "worse"]
};

var WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** "2026-11-02" -> "Mon 2 Nov". */
function dayLabel(day) {
  var d = new Date(dayToMs(day));
  return WEEKDAYS[d.getUTCDay()] + " " + d.getUTCDate() + " " + MONTHS[d.getUTCMonth()];
}
function two(n) { return (n < 10 ? "0" : "") + n; }
function n1(v) { return v === null || v === undefined ? "-" : (Math.round(v * 10) / 10).toFixed(1); }
function duration(min) {
  var m = Math.round(Math.abs(min));
  return m < 60 ? m + " min" : Math.floor(m / 60) + " h " + two(m % 60);
}
function clock(min) {
  var m = ((Math.round(min) % 1440) + 1440) % 1440;
  return two(Math.floor(m / 60)) + ":" + two(m % 60);
}
/** A measure's value as people read it. */
function valueText(k, v) {
  if (k === "sleep_min") return duration(v);
  if (k === "sleep_var") return Math.round(v) + " min";
  if (k === "midpoint") return clock(v);
  if (k === "steps") return Math.round(v) + " steps";
  if (k === "rhr") return n1(v) + " bpm";
  if (k === "hrv") return Math.round(v) + " ms";
  return n1(v) + " of 5";
}
/** A difference in a measure's units. */
function diffText(k, v) {
  v = Math.abs(v);
  if (k === "sleep_min" || k === "sleep_var" || k === "midpoint") return duration(v);
  if (k === "steps") return Math.round(v) + " steps";
  if (k === "rhr") return n1(v) + " bpm";
  if (k === "hrv") return n1(v) + " ms";
  return n1(v);
}
/** "7779 to 10549 steps", "02:57 to 03:37", "7 h 02 to 7 h 42". */
function rangeText(k, lo, hi) {
  if (k === "sleep_min" || k === "midpoint") return valueText(k, lo) + " to " + valueText(k, hi);
  var bare = k === "sleep_var" || k === "steps" || k === "hrv" ? String(Math.round(lo)) : n1(lo);
  return bare + " to " + valueText(k, hi);
}
function listWords(xs) {
  return xs.length <= 1 ? xs.join("") : xs.slice(0, -1).join(", ") + " and " + xs[xs.length - 1];
}

/* The daily readings each measure's value on day was worked out from. */
var RAW = { sleep_min: "sleep_min", midpoint: "midpoint", steps: "steps", rhr: "rhr", hrv: "hrv", mood: "mood", anxiety: "anxiety", energy: "energy", sleepq: "sleepq" };
function windowOf(s, k, day) {
  var out = [], i, d;
  if (k === "sleep_var") {
    for (i = 6; i >= 0; i--) {
      d = addDays(day, -i);
      out.push({ day: d, onset: isNum(s.onset[d]) ? s.onset[d] : null, wake: isNum(s.wake[d]) ? s.wake[d] : null });
    }
    return out;
  }
  var series = s[RAW[k]];
  for (i = SMOOTH - 1; i >= 0; i--) {
    d = addDays(day, -i);
    out.push({ day: d, value: isNum(series[d]) ? r2(series[d]) : null });
  }
  return out;
}

/** One measure on day: its value, the person's usual, how far, what counts, and the data behind it. */
function measureDetail(s, m, k, day) {
  var meta = MEASURES[k];
  var fn = m[k];
  var x = fn(day);
  if (!isNum(x)) x = null;
  var from = addDays(day, -(BASELINE_GAP + BASELINE_DAYS)), to = addDays(day, -(BASELINE_GAP + 1));
  var base = [], used = [];
  for (var i = BASELINE_GAP + BASELINE_DAYS; i >= BASELINE_GAP + 1; i--) {
    var d = addDays(day, -i);
    var b = fn(d);
    if (isNum(b)) { base.push(b); used.push({ day: d, value: r2(b) }); }
  }
  var enough = base.length >= BASELINE_MIN;
  var usual = enough ? median(base) : null;
  var mad = enough ? median(base.map(function (b) { return Math.abs(b - usual); })) : null;
  var spread = enough ? Math.max(1.4826 * mad, FLOOR[k] || 0) : null;
  // the same z as the rating (compare and robustZ above)
  var z = robustZ(x, base, FLOOR[k]);
  var away = z === null ? null : (meta.dir === "either" ? Math.abs(z) : meta.dir === "up" ? Math.max(0, z) : Math.max(0, -z));
  var out = {
    key: k, label: meta.label, domain: meta.domain, direction: meta.dir,
    value: r2(x),
    usual: r2(usual),
    spread: r2(spread),
    // the spread was raised to the measure's minimum (a very regular baseline)
    spreadFloor: enough ? 1.4826 * mad < (FLOOR[k] || 0) : false,
    low: enough ? r2(usual - spread) : null,
    high: enough ? r2(usual + spread) : null,
    z: r2(z),
    // how far in the direction that counts; watch measures count up to CAP, check-ins are averaged first
    away: r2(away),
    counts: away === null ? null : r2(meta.domain === "self" ? away : clip(away)),
    window: windowOf(s, k, day),
    baseline: { from: from, to: to, days: base.length, needed: BASELINE_MIN, values: used },
    rule: COUNTED[k],
    why: WHY[k]
  };
  out.words = measureWords(out, day);
  return out;
}

function measureWords(d, day) {
  var k = d.key, meta = MEASURES[k], when = dayLabel(day);
  var w = [];
  if (k === "sleep_var") {
    w.push(d.value === null
      ? "Sleep irregularity: too few nights in the 7 to " + when + " (it needs 4)."
      : "Sleep irregularity, how much the times they fell asleep and woke varied over the 7 nights to " + when + ": " + valueText(k, d.value) + ".");
  } else {
    w.push(d.value === null
      ? meta.label + ": too few readings in the 3 " + meta.per + " to " + when + " (it needs 2)."
      : meta.label + (meta.domain === "self" ? " in check-ins" : "") + ", averaged over the 3 " + meta.per + " to " + when + ": " + valueText(k, d.value) + ".");
  }
  if (d.usual === null) {
    w.push("Not enough earlier data to know their usual yet: " + d.baseline.days + " of the " + d.baseline.needed + " " + meta.per + " needed, between " +
      dayLabel(d.baseline.from) + " and " + dayLabel(d.baseline.to) + ".");
    return w.join(" ");
  }
  var low = k === "midpoint" ? d.low : Math.max(0, d.low);
  w.push("Usually " + valueText(k, d.usual) + ", give or take " + diffText(k, d.spread) + ", so " + rangeText(k, low, d.high) + ", from " +
    d.baseline.days + " " + meta.per + " between " + dayLabel(d.baseline.from) + " and " + dayLabel(d.baseline.to) + ".");
  if (d.spreadFloor) w.push("Their readings varied less than that, so RADR uses its smallest give-or-take for this measure.");
  if (d.value === null) return w.join(" ");
  var delta = d.value - d.usual;
  if (Math.abs(delta) < 0.005) w.push("Now the same as usual.");
  else w.push("Now " + diffText(k, delta) + " " + UP_DOWN[k][delta > 0 ? 0 : 1] + " than usual: " + n1(Math.abs(d.z)) + " times their usual give-or-take.");
  if (meta.domain === "self") {
    w.push(d.counts > 0 ? "It adds " + n1(d.counts) + " to the check-in score." : "It adds nothing: " + COUNTED[k].charAt(0).toLowerCase() + COUNTED[k].slice(1));
  } else {
    w.push(d.counts > 0
      ? "It counts " + n1(d.counts) + " of " + CAP + (d.away > CAP ? " (the most RADR counts)." : ".")
      : "It counts 0: " + COUNTED[k].charAt(0).toLowerCase() + COUNTED[k].slice(1));
  }
  return w.join(" ");
}

function domainWords(k, row, det, off) {
  var name = LABELS[k];
  if (off) return name + ": switched off for this patient, so not counted. Its measures are still shown.";
  var score = row.domains[k];
  if (score === null || score === undefined) return name + ": no data to compare on " + dayLabel(row.day) + ".";
  var c = function (x) { return det[x].counts === null ? "no data" : n1(det[x].counts); };
  var away = (row.away || []).indexOf(k) >= 0;
  var w = name + ": " + n1(score) + " of " + CAP + ", " + (away ? "away from usual (" + NOTABLE + " or more)" : "near usual (under " + NOTABLE + ")") + ". ";
  if (k === "sleep") w += "It is the larger of sleep length (" + c("sleep_min") + ") and sleep irregularity (" + c("sleep_var") + ").";
  else if (k === "circadian") w += "It is how far the middle of sleep moved" + (row.shift ? ", here " + row.shift + " than usual" : "") + ".";
  else if (k === "activity") w += "It is how far steps fell below usual.";
  else w += "It is the larger of resting heart rate (" + c("rhr") + ") and heart rate variability (" + c("hrv") + ").";
  return w;
}

function overallWords(row, excluded) {
  var when = dayLabel(row.day);
  if (row.watch === null) {
    return "Not rated on " + when + ": RADR needs " + BASELINE_MIN + " days of earlier data to compare with, and at least two areas with data.";
  }
  var counted = DOMAINS.length - excluded.length;
  var present = DOMAINS.filter(function (k) { return row.domains[k] !== null; }).length;
  var names = (row.away || []).map(function (k) { return LABELS[k].toLowerCase(); });
  var w = "On " + when + ", " + row.convergent + " of " + (counted < DOMAINS.length ? "the " + counted + " areas counted" : DOMAINS.length + " areas") + " " +
    (row.convergent === 1 ? "was" : "were") + " away from this person's usual (" + NOTABLE + " or more)" + (names.length ? ": " + listWords(names) : "") + ".";
  w += " The watch index, the average of the " + present + " areas with data, was " + n1(row.watch) + " of " + CAP + ".";
  w += row.self === null ? " No check-in score: too few recent check-ins to compare with their usual." :
    " The check-in score was " + n1(row.self) + " of " + CAP + ", and the two together " + n1(row.combined) + ".";
  return w + " 0 is usual for them, " + CAP + " is far from usual.";
}

function selfWords(row, det) {
  if (row.self === null) {
    return "Check-in score: not worked out. It needs at least two of mood, anxiety, energy and sleep with a value now and enough earlier check-ins to compare with.";
  }
  var parts = SELF_MEASURES.filter(function (k) { return det[k].counts !== null; })
    .map(function (k) { return MEASURES[k].label.toLowerCase() + " " + n1(det[k].counts); });
  return "Check-in score: " + n1(row.self) + " of " + CAP + ", the average of how far mood, energy and sleep were below their usual and anxiety above it (" +
    listWords(parts) + "), at most " + CAP + ". Shown beside the watch, not mixed into it.";
}

/**
 * Why day is rated as it is, in plain words, with the days and values behind each number. Uses
 * the same data and maths as rate() (byDay and checkins must reach back as far), and adds nothing.
 * opts.exclude: domains switched off for this patient.
 */
function explain(byDay, checkins, day, opts) {
  opts = opts || {};
  var exclude = (opts.exclude || []).filter(function (k) { return DOMAINS.indexOf(k) >= 0; });
  var s = rawSeries(byDay, checkins);
  var m = measures(s);
  var row = dayRating(s, day, m, exclude);
  var det = {};
  Object.keys(MEASURES).forEach(function (k) { det[k] = measureDetail(s, m, k, day); });
  var areas = {};
  DOMAINS.forEach(function (k) {
    var off = exclude.indexOf(k) >= 0;
    areas[k] = {
      key: k, label: LABELS[k], score: row.domains[k], counted: !off, away: row.away.indexOf(k) >= 0,
      measures: DOMAIN_MEASURES[k], words: domainWords(k, row, det, off)
    };
  });
  return {
    version: VERSION,
    day: day,
    rated: row.watch !== null,
    watch: row.watch,
    self: row.self,
    combined: row.combined,
    convergent: row.convergent,
    away: row.away,
    shift: row.shift,
    words: overallWords(row, exclude),
    domains: areas,
    checkins: { score: row.self, measures: SELF_MEASURES, words: selfWords(row, det) },
    measures: det,
    excluded: exclude,
    method: { baselineDays: BASELINE_DAYS, baselineGap: BASELINE_GAP, baselineMin: BASELINE_MIN, smoothDays: SMOOTH, notable: NOTABLE, cap: CAP }
  };
}

module.exports = {
  VERSION: VERSION,
  FLOOR: FLOOR,
  level: level,
  flags: flags,
  explain: explain,
  dayLabel: dayLabel,
  MEASURES: MEASURES,
  GAP_MAX: GAP_MAX,
  BASELINE_DAYS: BASELINE_DAYS,
  BASELINE_GAP: BASELINE_GAP,
  SMOOTH: SMOOTH,
  NOTABLE: NOTABLE,
  DOMAINS: DOMAINS,
  LABELS: LABELS,
  addDays: addDays,
  midpoint: midpoint,
  robustZ: robustZ,
  spearman: spearman,
  rate: rate
};
