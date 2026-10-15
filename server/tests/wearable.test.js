// SPDX-License-Identifier: AGPL-3.0-or-later
const test = require("node:test");
const assert = require("node:assert/strict");
const w = require("../pb_hooks/lib/wearable.js");

test("day arithmetic crosses months and leap years", () => {
  assert.equal(w.addDays("2026-10-01", -1), "2026-09-30");
  assert.equal(w.addDays("2028-02-28", 1), "2028-02-29");
  assert.equal(w.addDays("2026-12-31", 1), "2027-01-01");
  assert.equal(w.validDay("2026-02-30"), false);
  assert.equal(w.validDay("2026-10-15"), true);
  assert.equal(w.validDay("15/10/2026"), false);
});

test("local day uses the patient's offset", () => {
  const ms = Date.UTC(2026, 9, 14, 23, 30); // 23:30 UTC = 01:30 SAST next day
  assert.equal(w.localDay(ms, 0), "2026-10-14");
  assert.equal(w.localDay(ms, 120), "2026-10-15");
});

test("cleanDay keeps plausible values and drops the rest", () => {
  const c = w.cleanDay({
    day: "2026-10-14",
    values: { rhr: 58.26, hr_avg: 400, steps: 8123, spo2_avg: 97, rhr_method: "sleep", junk: 1, sleep_min: "lots" }
  }, "2026-10-15");
  assert.equal(c.ok, true);
  assert.deepEqual(c.values, { rhr: 58.3, steps: 8123, spo2_avg: 97, rhr_method: "sleep" });
  assert.deepEqual(c.dropped.sort(), ["hr_avg", "junk", "sleep_min"]);
});

test("cleanDay refuses bad and future dates", () => {
  assert.equal(w.cleanDay({ day: "2026-10-17", values: {} }, "2026-10-15").ok, false);
  assert.equal(w.cleanDay({ day: "2026-10-16", values: {} }, "2026-10-15").ok, true, "one day ahead allowed for time zones");
  assert.equal(w.cleanDay({ day: "2024-01-01", values: {} }, "2026-10-15").ok, false);
  assert.equal(w.cleanDay({ day: "nope" }, "2026-10-15").ok, false);
  assert.equal(w.cleanDay(null, "2026-10-15").ok, false);
});

test("cleanDay drops an impossible min/max pair", () => {
  const c = w.cleanDay({ day: "2026-10-14", values: { hr_min: 90, hr_max: 60, hr_avg: 70 } }, "2026-10-15");
  assert.deepEqual(c.values, { hr_avg: 70 });
});

test("percentile interpolates", () => {
  assert.equal(w.percentile([1, 2, 3, 4, 5], 0.5), 3);
  assert.equal(w.percentile([10, 20], 0.5), 15);
  assert.equal(w.percentile([], 0.5), null);
});

test("baseline needs 7 earlier readings and excludes the day itself", () => {
  const byDay = {};
  for (let i = 1; i <= 10; i++) byDay[w.addDays("2026-10-01", i - 1)] = { rhr: 60 + i }; // Oct 1..10: 61..70
  const b = w.baselines(byDay, "2026-10-07", "2026-10-11", ["rhr"]).rhr;
  assert.equal(b.length, 5);
  // Oct 7 sees Oct 1-6 = 6 readings: not enough yet
  assert.deepEqual(b[0], { day: "2026-10-07", lo: null, mid: null, hi: null, n: 6 });
  // Oct 8 sees Oct 1-7 = 61..67
  assert.equal(b[1].n, 7);
  assert.equal(b[1].mid, 64);
  assert.equal(b[1].lo, 61.6);
  assert.equal(b[1].hi, 66.4);
  // Oct 11 sees Oct 1-10, its own value isn't in the window
  assert.equal(b[4].n, 10);
  assert.equal(b[4].mid, 65.5);
});

test("baseline window is 28 days and skips gaps", () => {
  const byDay = {};
  for (let i = 0; i < 60; i++) if (i % 3 !== 0) byDay[w.addDays("2026-08-01", i)] = { steps: 1000 * (i % 7) };
  const b = w.baselines(byDay, "2026-09-29", "2026-09-29", ["steps"]).steps[0];
  assert.ok(b.n <= 28 && b.n >= 18, "about two thirds of 28 days have data: " + b.n);
  assert.ok(b.lo <= b.mid && b.mid <= b.hi);
});

test("only baselined metrics get a range by default", () => {
  const b = w.baselines({}, "2026-10-01", "2026-10-01");
  assert.ok(b.rhr && b.sleep_min && b.steps && b.spo2_avg);
  assert.equal(b.hr_samples, undefined);
  assert.equal(b.sleep_deep, undefined);
});
