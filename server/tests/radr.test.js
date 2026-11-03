// SPDX-License-Identifier: AGPL-3.0-or-later
// RADR (lib/radr.js) on the fictional demo patients (lib/research_demo.js).
const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const R = require(path.join(__dirname, "..", "pb_hooks", "lib", "radr.js"));
const G = require(path.join(__dirname, "..", "pb_hooks", "lib", "research_demo.js"));

const NOW = Date.UTC(2026, 9, 22, 8);

function rated(key) {
  const p = G.generate(NOW, 120).find((x) => x.key === key);
  const byDay = {}, ck = {};
  p.days.forEach((d) => { byDay[d.day] = d.values; });
  p.checkins.forEach((c) => { ck[new Date(c.at + 120 * 60000).toISOString().slice(0, 10)] = c; });
  const days = Object.keys(byDay).sort();
  return { p, res: R.rate(byDay, ck, days[0], days[days.length - 1]) };
}

test("RADR: no rating until the person has a baseline of their own", () => {
  const { res } = rated("steady");
  assert.equal(res.days[0].watch, null);
  assert.ok(res.days.filter((d) => d.watch !== null).length >= 30);
});

test("RADR: the steady demo stays low; two domains together happen rarely, three never", () => {
  const r = rated("steady").res.days.filter((d) => d.watch !== null);
  assert.ok(Math.max(...r.map((d) => d.watch)) < 1.5);
  assert.ok(Math.max(...r.map((d) => d.convergent)) <= 2);
  assert.ok(r.filter((d) => d.convergent >= 2).length <= 3);
});

test("RADR: the decline and disruption demos converge across domains, and track check-ins", () => {
  for (const key of ["decline", "disruption"]) {
    const { res } = rated(key);
    const last = res.days.filter((d) => d.watch !== null).slice(-7);
    assert.ok(last.every((d) => d.convergent >= 2), key);
    assert.ok(last.some((d) => d.watch >= 2), key);
    assert.ok(res.concordance[0].rho > 0.5, key);
  }
  const steady = rated("steady").res;
  assert.ok(Math.abs(steady.concordance[0].rho) < 0.4);
});

test("RADR: helpers", () => {
  assert.equal(R.midpoint({ sleep_onset: -60, sleep_wake: 420 }), 180);
  assert.equal(R.midpoint({ sleep_onset: 1380, sleep_wake: 420 }), 1620);
  assert.equal(R.robustZ(5, [1, 2], 1), null, "too little baseline");
  const base = Array.from({ length: 20 }, (_, i) => 10 + (i % 3));
  assert.ok(R.robustZ(20, base, 1) > 5);
  assert.equal(R.spearman([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], [2, 4, 6, 8, 10, 12, 14, 16, 18, 20]), 1);
});

test("RADR explained: the same numbers as the rating, in plain words, with the days and values behind them", () => {
  const { p, res } = rated("decline");
  const byDay = {}, ck = {};
  p.days.forEach((d) => { byDay[d.day] = d.values; });
  p.checkins.forEach((c) => { ck[new Date(c.at + 120 * 60000).toISOString().slice(0, 10)] = c; });
  const day = res.latest.day;
  const x = R.explain(byDay, ck, day);
  // nothing new: the same scores and distances as rate()
  assert.equal(x.watch, res.latest.watch);
  assert.equal(x.self, res.latest.self);
  assert.equal(x.convergent, res.latest.convergent);
  assert.deepEqual(x.away, res.latest.away);
  for (const k of R.DOMAINS) assert.equal(x.domains[k].score, res.latest.domains[k], k);
  for (const k of Object.keys(R.MEASURES)) {
    const f = res.latest.features[k], m = x.measures[k];
    assert.equal(m.z, f.z, k);
    assert.equal(m.value, f.value, k);
    assert.equal(m.usual, f.usual, k);
  }
  // each measure: the value now, the usual range, how far, what counts, why, and the data
  const st = x.measures.steps;
  assert.equal(st.direction, "down");
  assert.ok(st.low < st.usual && st.usual < st.high && Math.abs((st.high - st.low) / 2 - st.spread) < 0.02);
  assert.equal(st.counts, Math.min(4, Math.max(0, -st.z)));
  assert.match(st.words, /^Steps, averaged over the 3 days to \w{3} \d+ \w{3}: \d+ steps\. Usually \d+ steps, give or take \d+ steps, so \d+ to \d+ steps, from \d+ days between .* Now \d+ steps fewer than usual: \d\.\d times their usual give-or-take\. It counts \d\.\d of 4\.$/);
  assert.match(st.rule, /Only fewer steps/);
  assert.match(st.why, /Rykov/);
  // the window: the 3 daily readings averaged; the baseline: the 28 days ending a week before
  assert.deepEqual(st.window.map((w) => w.day), [R.addDays(day, -2), R.addDays(day, -1), day]);
  const raw = st.window.map((w) => w.value).filter((v) => v !== null);
  assert.ok(Math.abs(raw.reduce((a, b) => a + b, 0) / raw.length - st.value) < 0.01);
  assert.equal(st.baseline.from, R.addDays(day, -35));
  assert.equal(st.baseline.to, R.addDays(day, -8));
  assert.equal(st.baseline.values.length, st.baseline.days);
  const sorted = st.baseline.values.map((v) => v.value).sort((a, b) => a - b);
  const mid = sorted.length % 2 ? sorted[(sorted.length - 1) / 2] : (sorted[sorted.length / 2 - 1] + sorted[sorted.length / 2]) / 2;
  assert.ok(Math.abs(mid - st.usual) < 0.02, "usual is the middle of the values listed");
  // irregular sleep: the 7 nights of falling asleep and waking
  assert.equal(x.measures.sleep_var.window.length, 7);
  assert.ok("onset" in x.measures.sleep_var.window[0] && "wake" in x.measures.sleep_var.window[0]);
  // domains and the whole day, in words
  assert.match(x.words, /^On \w{3} \d+ \w{3}, 3 of 4 areas were away from this person's usual \(1\.5 or more\): sleep, body clock and activity\. The watch index/);
  assert.match(x.domains.activity.words, /^Activity: \d\.\d of 4, away from usual \(1\.5 or more\)\. It is how far steps fell below usual\.$/);
  assert.match(x.domains.cardiac.words, /near usual \(under 1\.5\)\. It is the larger of resting heart rate \(\d\.\d\) and heart rate variability \(no data\)\.$/);
  assert.match(x.checkins.words, /^Check-in score: \d\.\d of 4/);
  assert.ok(!/risk|alert|alarm/i.test(JSON.stringify(x)), "no alarm wording");
  // a domain switched off: still shown, not counted
  const off = R.explain(byDay, ck, day, { exclude: ["sleep"] });
  assert.equal(off.domains.sleep.score, null);
  assert.equal(off.domains.sleep.counted, false);
  assert.match(off.domains.sleep.words, /switched off for this patient/);
  assert.ok(off.measures.sleep_min.value !== null);
  assert.match(off.words, /of the 3 areas counted/);
  // too little history: says so, with how many days there were
  const early = R.explain(byDay, ck, Object.keys(byDay).sort()[5]);
  assert.equal(early.rated, false);
  assert.match(early.words, /^Not rated on/);
  assert.match(early.measures.rhr.words, /Not enough earlier data to know their usual yet: \d+ of the 14 days needed/);
});

test("RADR flags: one per domain away from usual, with a key that holds until something new appears", () => {
  const row = (day, dom) => {
    const domains = Object.assign({ sleep: 0.2, circadian: 0.1, activity: 0.3, cardiac: 0.2 }, dom || {});
    const away = R.DOMAINS.filter((k) => domains[k] !== null && domains[k] >= 1.5);
    return { day, watch: 1, domains, away, convergent: away.length };
  };
  const day = (i) => R.addDays("2026-10-01", i);
  // sleep away from day 3 on; heart from day 6 on
  const rows = [];
  for (let i = 0; i < 12; i++) rows.push(row(day(i), { sleep: i >= 3 ? 2.5 : 0.4, cardiac: i >= 6 ? 1.8 : 0.5 }));
  let f = R.flags(rows);
  assert.deepEqual(f.map((x) => x.key), ["radr:sleep:" + day(3), "radr:cardiac:" + day(6)]);
  assert.ok(f.every((x) => x.open === false && x.day === day(11)));
  assert.equal(f[0].label, "Sleep away from usual");
  // the same key day after day while the run lasts (a review holds)
  assert.equal(R.flags(rows.slice(0, 9))[0].key, f[0].key);
  // back to usual for a day, then away again: a new key (something new)
  const again = rows.concat([row(day(12), { sleep: 0.9 }), row(day(13), { sleep: 2.1 })]);
  assert.equal(R.flags(again).find((x) => x.domain === "sleep").key, "radr:sleep:" + day(13));
  // days without data don't end a run, unless more than a week of them
  const gap = rows.concat([1, 2, 3].map((i) => row(day(11 + i), { sleep: null })), [row(day(15), { sleep: 3 })]);
  assert.equal(R.flags(gap).find((x) => x.domain === "sleep").key, "radr:sleep:" + day(3));
  const long = rows.concat(Array.from({ length: 8 }, (_, i) => row(day(12 + i), { sleep: null })), [row(day(20), { sleep: 3 })]);
  assert.equal(R.flags(long).find((x) => x.domain === "sleep").key, "radr:sleep:" + day(20));
  // a run reaching the first day given needs more days to be sure where it starts
  assert.equal(R.flags(rows.slice(4))[0].open, true);
  // the latest rated day counts; unrated days after it don't
  assert.equal(R.flags(rows.concat([{ day: day(12), watch: null, domains: {}, away: [] }]))[0].day, day(11));
  assert.deepEqual(R.flags([]), []);
  // on the real demo: as many flags as domains away
  const { res } = rated("disruption");
  assert.equal(R.flags(res.days).length, res.latest.convergent);
});

test("RADR level: an ordering of data, never an alert; reviewed until something new appears", () => {
  const today = "2026-10-20";
  const latest = (extra) => Object.assign({ day: today, watch: 2, convergent: 2, domains: { sleep: 2, circadian: 1.6 } }, extra || {});
  assert.equal(R.level(null, today), "none");
  assert.equal(R.level(latest({ convergent: 0 }), today), "none");
  assert.equal(R.level(latest({ day: "2026-10-16" }), today), "none", "older than 3 days");
  assert.equal(R.level(latest(), today), "away", "kept before flags existed");
  const fl = [{ key: "radr:sleep:2026-10-15", reviewed: { by: "Dr", at: 1 } }, { key: "radr:circadian:2026-10-19", reviewed: null }];
  assert.equal(R.level(latest({ flags: fl }), today), "away");
  fl[1].reviewed = { by: "Dr", at: 2 };
  assert.equal(R.level(latest({ flags: fl }), today), "reviewed");
  for (const v of ["alert", "warn", "info"]) {
    assert.notEqual(R.level(latest({ convergent: 4 }), today), v);
  }
});

test("demo data: PHQ-9 answers add up and stay in range; item 9 only in the disruption demo", () => {
  for (const p of G.generate(NOW, 120)) {
    for (const q of p.questionnaires) {
      for (const v of Object.values(q.answers)) assert.ok(v >= 0 && v <= 3);
    }
    const item9 = p.questionnaires.filter((q) => q.key === "phq9").some((q) => q.answers.phq9_9 > 0);
    assert.equal(item9, p.key === "disruption", p.key);
  }
});
