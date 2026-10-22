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

test("demo data: PHQ-9 answers add up and stay in range; item 9 only in the disruption demo", () => {
  for (const p of G.generate(NOW, 120)) {
    for (const q of p.questionnaires) {
      for (const v of Object.values(q.answers)) assert.ok(v >= 0 && v <= 3);
    }
    const item9 = p.questionnaires.filter((q) => q.key === "phq9").some((q) => q.answers.phq9_9 > 0);
    assert.equal(item9, p.key === "disruption", p.key);
  }
});
