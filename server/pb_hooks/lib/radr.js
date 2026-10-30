/*
 * Steady - RADR, the Research Amon Dîn Rating (pure logic, ES2015, no PocketBase globals).
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * A research view, not a risk score, prediction or diagnosis. It exists so the practice can
 * study, in ordinary clinical care, what the research on passive watch data reports: that single
 * measures say little on their own, and that change shows when several domains move away from the
 * person's own normal at the same time, and alongside what the person reports.
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
 *     watch leading by 0 to 3 days. This is the research question: does passive data add anything
 *     over what the person tells us, and does it move first?
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
  var convergent = present.filter(function (k) { return domains[k] >= NOTABLE; }).length;

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
 * How much a rated day asks for attention, used only to order the psychologist's patient list
 * (never shown as a risk): how many domains are away from usual on the same day.
 * A day older than 3 days counts for nothing.
 */
function level(latest, today) {
  if (!latest || latest.watch === null || latest.watch === undefined) return "none";
  if (today && addDays(latest.day, 3) < today) return "none";
  var c = latest.convergent || 0;
  return c >= 3 ? "alert" : c >= 2 ? "warn" : c >= 1 ? "info" : "none";
}

module.exports = {
  VERSION: VERSION,
  FLOOR: FLOOR,
  level: level,
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
