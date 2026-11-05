/*
 * Steady - loads a patient's watch data, check-ins and questionnaire totals and works out RADR
 * (lib/radr.js) for a range of local days. Used by the RADR tab, its explanations and reviews,
 * the order of the psychologist's list, and exports.
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

var s = require(__hooks + "/lib/server.js");
var w = require(__hooks + "/lib/wearable.js");
var R = require(__hooks + "/lib/radr.js");

/** The watch days and daily check-in means RADR needs for from..to (YYYY-MM-DD, local days). */
function load(app, p, from, to) {
  var tz = p.getInt("tzOffset") || 120;
  var reach = R.addDays(from, -(R.BASELINE_GAP + R.BASELINE_DAYS + 7));

  var byDay = {};
  app.findRecordsByFilter("biometrics", "patient = {:p} && day >= {:a} && day <= {:b}", "day", 5000, 0, { p: p.id, a: reach, b: to })
    .forEach(function (r) { byDay[r.getString("day")] = s.readJson(r, "values") || {}; });

  // check-ins: one mean per local day
  var sums = {};
  var since = s.dateValue(Date.parse(reach + "T00:00:00Z") - tz * 60000).string();
  app.findRecordsByFilter("checkins", "patient = {:p} && created >= {:a}", "created", 20000, 0, { p: p.id, a: since })
    .forEach(function (r) {
      var d = w.localDay(s.toMs(r, "created"), tz);
      var o = sums[d] || (sums[d] = { n: 0, mood: 0, anxiety: 0, sleep: 0, energy: 0 });
      o.n++;
      ["mood", "anxiety", "sleep", "energy"].forEach(function (k) { o[k] += r.getInt(k); });
    });
  var checkins = {};
  Object.keys(sums).forEach(function (d) {
    var o = sums[d];
    checkins[d] = { mood: o.mood / o.n, anxiety: o.anxiety / o.n, sleep: o.sleep / o.n, energy: o.energy / o.n };
  });
  return { byDay: byDay, checkins: checkins };
}

function excluded(p) { return exclusions(p).map(function (x) { return x.domain; }); }

/** from, to: YYYY-MM-DD in the patient's local time. */
function forPatient(app, p, from, to) {
  var tz = p.getInt("tzOffset") || 120;
  var d = load(app, p, from, to);
  var out = R.rate(d.byDay, d.checkins, from, to, { exclude: excluded(p) });
  out.exclusions = exclusions(p);

  // questionnaire totals in the period, for the chart
  var names = {};
  out.questionnaires = app.findRecordsByFilter("assignments", "patient = {:p} && status = 'done' && completedAt >= {:a}", "completedAt", 2000, 0,
    { p: p.id, a: s.dateValue(Date.parse(from + "T00:00:00Z") - tz * 60000).string() })
    .map(function (a) {
      var score = s.readJson(a, "score");
      if (!score || typeof score.total !== "number") return null;
      var id = a.getString("instrument");
      if (names[id] === undefined) {
        try { var i = app.findRecordById("instruments", id); names[id] = { key: i.getString("key"), name: i.getString("name") }; } catch (e) { names[id] = null; }
      }
      if (!names[id]) return null;
      return { day: w.localDay(s.toMs(a, "completedAt"), tz), key: names[id].key, name: names[id].name, total: score.total, max: score.max, severity: score.severity || "none" };
    })
    .filter(function (x) { return x; });
  out.demo = p.getBool("demo");
  out.watchConnected = s.toMs(p, "wearableConsentAt") > 0;
  return out;
}

/** Measures switched off for this patient: [{ domain, since, by, reason }]. */
function exclusions(p) {
  var v = s.readJson(p, "radrExclusions");
  return Array.isArray(v) ? v.filter(function (x) { return x && R.DOMAINS.indexOf(x.domain) >= 0; }) : [];
}

/** Reviews of this patient's RADR flags: { key: { by, at, note } } (radrreviews). */
function reviews(app, p) {
  var out = {};
  app.findRecordsByFilter("radrreviews", "patient = {:p}", "-updated", 500, 0, { p: p.id }).forEach(function (r) {
    var k = r.getString("key");
    if (!out[k]) out[k] = { by: r.getString("reviewerName"), at: s.toMs(r, "updated") || s.toMs(r, "created"), note: r.getString("note") };
  });
  return out;
}

/* Days back from today that current() works RADR out on: the first that holds the start of every
   run of days away from usual. Almost always the first (a lasting change is soon part of the
   person's own baseline). */
var LOOK = [7, 35, 91];

/**
 * The patient's RADR now: the latest rated day of the last week, and its flags (lib/radr.js
 * flags) each with its review, if any. The same answer for the list, the RADR tab and a review.
 */
function current(app, p) {
  var tz = p.getInt("tzOffset") || 120;
  var to = w.localDay(s.nowMs(), tz);
  var r = null, fl = [];
  for (var i = 0; i < LOOK.length; i++) {
    var from = R.addDays(to, -(LOOK[i] - 1));
    var d = load(app, p, from, to);
    r = R.rate(d.byDay, d.checkins, from, to, { exclude: excluded(p) });
    fl = R.flags(r.days);
    if (!fl.some(function (f) { return f.open; })) break;
  }
  var rv = fl.length ? reviews(app, p) : {};
  fl.forEach(function (f) { delete f.open; f.reviewed = rv[f.key] || null; });
  return { result: r, latest: r.latest, flags: fl };
}

/** One day explained (lib/radr.js explain), with what is switched off for this patient. */
function explain(app, p, day) {
  var d = load(app, p, day, day);
  var out = R.explain(d.byDay, d.checkins, day, { exclude: excluded(p) });
  out.exclusions = exclusions(p);
  out.demo = p.getBool("demo");
  return out;
}

/** Marks one of the patient's current flags as reviewed by who (a staff record): who and when. */
function markReviewed(app, p, flag, who, note) {
  var r = null;
  try { r = app.findFirstRecordByFilter("radrreviews", "patient = {:p} && key = {:k}", { p: p.id, k: flag.key }); } catch (e) { r = null; }
  if (!r) {
    r = new Record(app.findCollectionByNameOrId("radrreviews"));
    r.set("patient", p.id);
    r.set("key", flag.key);
  }
  r.set("domain", flag.domain);
  r.set("since", flag.since);
  r.set("day", flag.day);
  r.set("score", flag.score);
  r.set("reviewer", who.id);
  r.set("reviewerName", who.getString("name"));
  r.set("note", note || "");
  app.save(r);
  return { by: who.getString("name"), at: s.toMs(r, "updated") || s.nowMs(), note: note || "" };
}

/**
 * Works out the patient's latest RADR day and its flags and keeps them on their account
 * (radrLatest), so the patient list can be ordered without working RADR out for everyone each
 * time. Called when watch data arrives, when measures are switched off or on, when a flag is
 * marked as reviewed, and nightly.
 */
function refreshLatest(app, p) {
  if (s.toMs(p, "wearableConsentAt") === 0) {
    if (p.getString("radrLatest") && p.getString("radrLatest") !== "null") { p.set("radrLatest", null); app.unsafeWithoutHooks().save(p); }
    return null;
  }
  var c = current(app, p);
  var l = c.latest;
  var keep = l ? {
    day: l.day, watch: l.watch, self: l.self, combined: l.combined, convergent: l.convergent, domains: l.domains, version: c.result.version,
    flags: c.flags.map(function (f) {
      return { key: f.key, domain: f.domain, since: f.since, score: f.score, reviewed: f.reviewed ? { by: f.reviewed.by, at: f.reviewed.at } : null };
    })
  } : null;
  p.set("radrLatest", keep);
  app.unsafeWithoutHooks().save(p);
  return keep;
}

/** The trimmed version for exports: no per-measure detail. */
function compact(r) {
  return {
    version: r.version,
    method: r.method,
    exclusions: r.exclusions || [],
    from: r.from,
    to: r.to,
    wearDays: r.wearDays,
    checkinDays: r.checkinDays,
    concordance: r.concordance,
    latest: r.latest ? { day: r.latest.day, watch: r.latest.watch, self: r.latest.self, combined: r.latest.combined, convergent: r.latest.convergent, domains: r.latest.domains, shift: r.latest.shift, features: r.latest.features || null } : null,
    // each measure's value and usual (baseline) value on the first rated day: "where things stood"
    start: (function () {
      var first = r.days.filter(function (d) { return d.watch !== null && d.watch !== undefined; })[0];
      return first ? { day: first.day, features: first.features || null } : null;
    })(),
    days: r.days.map(function (d) {
      return { day: d.day, watch: d.watch, self: d.self, combined: d.combined, convergent: d.convergent, domains: d.domains };
    })
  };
}

module.exports = {
  forPatient: forPatient, compact: compact, exclusions: exclusions, refreshLatest: refreshLatest,
  current: current, explain: explain, reviews: reviews, markReviewed: markReviewed
};
