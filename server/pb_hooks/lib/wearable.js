/*
 * Steady - wearable daily summaries and personal baselines (pure logic).
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The phone reads the watch's data from Health Connect / Apple Health, reduces it to one
 * summary per day, and uploads that. The server validates the summaries, stores them, and
 * works out each patient's own normal range for display. No alerts are raised from this data.
 * Keep to ES2015 for goja.
 */

var DAY_RE = /^\d{4}-\d{2}-\d{2}$/;

/* Allowed daily values and plausible ranges. Out-of-range values are dropped, not stored. */
var METRICS = {
  rhr: { min: 25, max: 150, label: "Resting heart rate", unit: "bpm", baseline: true },
  hr_min: { min: 20, max: 220, label: "Lowest heart rate", unit: "bpm", baseline: false },
  hr_avg: { min: 25, max: 220, label: "Average heart rate", unit: "bpm", baseline: true },
  hr_max: { min: 30, max: 250, label: "Highest heart rate", unit: "bpm", baseline: false },
  hr_samples: { min: 0, max: 200000, label: "Heart rate readings", unit: "", baseline: false },
  sleep_min: { min: 0, max: 1440, label: "Sleep", unit: "min", baseline: true },
  sleep_deep: { min: 0, max: 1440, label: "Deep sleep", unit: "min", baseline: false },
  sleep_light: { min: 0, max: 1440, label: "Light sleep", unit: "min", baseline: false },
  sleep_rem: { min: 0, max: 1440, label: "REM sleep", unit: "min", baseline: false },
  sleep_awake: { min: 0, max: 1440, label: "Awake in bed", unit: "min", baseline: false },
  sleep_onset: { min: -720, max: 720, label: "Fell asleep", unit: "min from midnight", baseline: true },
  sleep_wake: { min: -720, max: 1440, label: "Woke up", unit: "min from midnight", baseline: true },
  steps: { min: 0, max: 150000, label: "Steps", unit: "steps", baseline: true },
  spo2_avg: { min: 50, max: 100, label: "Blood oxygen", unit: "%", baseline: true },
  spo2_min: { min: 40, max: 100, label: "Lowest blood oxygen", unit: "%", baseline: false }
};
var TEXT_FIELDS = { rhr_method: ["sleep", "awake"] };

var BASELINE_WINDOW = 28; // days before the day being compared
var BASELINE_MIN = 7;     // readings needed before a range is shown

function isNum(v) { return typeof v === "number" && isFinite(v); }

/* "2026-10-15" <-> UTC midnight ms, so day arithmetic never meets DST or local zones. */
function dayToMs(day) {
  var p = day.split("-");
  return Date.UTC(+p[0], +p[1] - 1, +p[2]);
}
function msToDay(ms) {
  var d = new Date(ms);
  var m = d.getUTCMonth() + 1, dd = d.getUTCDate();
  return d.getUTCFullYear() + "-" + (m < 10 ? "0" : "") + m + "-" + (dd < 10 ? "0" : "") + dd;
}
function addDays(day, n) { return msToDay(dayToMs(day) + n * 86400000); }
function validDay(day) { return typeof day === "string" && DAY_RE.test(day) && msToDay(dayToMs(day)) === day; }

/** The patient's local date for a moment, given their offset from UTC in minutes. */
function localDay(ms, tzOffsetMinutes) { return msToDay(ms + (tzOffsetMinutes || 0) * 60000); }

/**
 * Validates one uploaded day. Returns { ok, day, values, dropped, error }.
 * todayLocal: the patient's current date, so tomorrow (and beyond) is refused.
 */
function cleanDay(input, todayLocal, maxAgeDays) {
  if (!input || typeof input !== "object") return { ok: false, error: "each day must be an object" };
  var day = input.day;
  if (!validDay(day)) return { ok: false, error: "day must be YYYY-MM-DD" };
  if (day > addDays(todayLocal, 1)) return { ok: false, error: day + " is in the future" };
  if (day < addDays(todayLocal, -(maxAgeDays || 400))) return { ok: false, error: day + " is too old" };
  var src = input.values && typeof input.values === "object" ? input.values : {};
  var out = {};
  var dropped = [];
  Object.keys(src).forEach(function (k) {
    var v = src[k];
    if (METRICS[k]) {
      if (isNum(v) && v >= METRICS[k].min && v <= METRICS[k].max) out[k] = Math.round(v * 10) / 10;
      else dropped.push(k);
    } else if (TEXT_FIELDS[k]) {
      if (TEXT_FIELDS[k].indexOf(v) >= 0) out[k] = v;
      else dropped.push(k);
    } else {
      dropped.push(k);
    }
  });
  if (out.hr_min !== undefined && out.hr_max !== undefined && out.hr_min > out.hr_max) {
    delete out.hr_min; delete out.hr_max; dropped.push("hr_min", "hr_max");
  }
  return { ok: true, day: day, values: out, dropped: dropped };
}

function percentile(sorted, p) {
  if (!sorted.length) return null;
  var idx = (sorted.length - 1) * p;
  var lo = Math.floor(idx), hi = Math.ceil(idx);
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (idx - lo);
}
function r1(n) { return n === null ? null : Math.round(n * 10) / 10; }

/**
 * Personal normal range for each day in [from, to]: the 10th to 90th percentile of that
 * patient's own values over the previous 28 days (the day itself excluded).
 * byDay: { "2026-10-01": { rhr: 61, ... }, ... }
 * Returns { metric: [ { day, lo, mid, hi, n } ] } with lo/mid/hi null until 7 readings exist.
 */
function baselines(byDay, from, to, metrics) {
  var out = {};
  var keys = metrics || Object.keys(METRICS).filter(function (k) { return METRICS[k].baseline; });
  var span = Math.round((dayToMs(to) - dayToMs(from)) / 86400000);
  keys.forEach(function (k) {
    var series = [];
    for (var i = 0; i <= span; i++) {
      var day = addDays(from, i);
      var window = [];
      for (var j = 1; j <= BASELINE_WINDOW; j++) {
        var v = byDay[addDays(day, -j)];
        if (v && isNum(v[k])) window.push(v[k]);
      }
      window.sort(function (a, b) { return a - b; });
      var enough = window.length >= BASELINE_MIN;
      series.push({
        day: day,
        lo: enough ? r1(percentile(window, 0.1)) : null,
        mid: enough ? r1(percentile(window, 0.5)) : null,
        hi: enough ? r1(percentile(window, 0.9)) : null,
        n: window.length
      });
    }
    out[k] = series;
  });
  return out;
}

module.exports = {
  METRICS: METRICS,
  BASELINE_WINDOW: BASELINE_WINDOW,
  BASELINE_MIN: BASELINE_MIN,
  validDay: validDay,
  addDays: addDays,
  localDay: localDay,
  cleanDay: cleanDay,
  baselines: baselines,
  percentile: percentile
};
