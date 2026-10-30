/*
 * Steady - loads a patient's watch data, check-ins and questionnaire totals and works out RADR
 * (lib/radr.js) for a range of local days. Used by the RADR tab and by exports.
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

var s = require(__hooks + "/lib/server.js");
var w = require(__hooks + "/lib/wearable.js");
var R = require(__hooks + "/lib/radr.js");

/** from, to: YYYY-MM-DD in the patient's local time. */
function forPatient(app, p, from, to) {
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

  var out = R.rate(byDay, checkins, from, to, { exclude: exclusions(p).map(function (x) { return x.domain; }) });
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

/**
 * Works out the patient's latest RADR day and keeps it on their account (radrLatest), so the
 * patient list can be ordered without working RADR out for everyone each time. Called when watch
 * data or a check-in arrives, when measures are switched off or on, and nightly.
 */
function refreshLatest(app, p) {
  if (s.toMs(p, "wearableConsentAt") === 0) {
    if (p.getString("radrLatest") && p.getString("radrLatest") !== "null") { p.set("radrLatest", null); app.unsafeWithoutHooks().save(p); }
    return null;
  }
  var tz = p.getInt("tzOffset") || 120;
  var to = w.localDay(s.nowMs(), tz);
  var r = forPatient(app, p, R.addDays(to, -6), to);
  var l = r.latest;
  var keep = l ? { day: l.day, watch: l.watch, self: l.self, combined: l.combined, convergent: l.convergent, domains: l.domains, version: r.version } : null;
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
    latest: r.latest ? { day: r.latest.day, watch: r.latest.watch, self: r.latest.self, combined: r.latest.combined, convergent: r.latest.convergent, domains: r.latest.domains, shift: r.latest.shift } : null,
    days: r.days.map(function (d) {
      return { day: d.day, watch: d.watch, self: d.self, combined: d.combined, convergent: d.convergent, domains: d.domains };
    })
  };
}

module.exports = { forPatient: forPatient, compact: compact, exclusions: exclusions, refreshLatest: refreshLatest };
