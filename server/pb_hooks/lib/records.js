/*
 * Steady - one patient's record for a date range, for exports (PDF and Excel in the app) and
 * the Sorted feed. Uses PocketBase globals; require() it inside handlers.
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

var s = require(__hooks + "/lib/server.js");
var core = s.core;

function iso(ms) { return ms ? new Date(ms).toISOString() : null; }

/** Parses YYYY-MM-DD (or empty) into a [fromMs, toMs] range of at most maxDays, ending today. */
function range(q, maxDays, defaultDays) {
  var day = /^\d{4}-\d{2}-\d{2}$/;
  var now = s.nowMs();
  var to = day.test(String(q.to || "")) ? Date.parse(q.to + "T23:59:59.999Z") : now;
  var from = day.test(String(q.from || "")) ? Date.parse(q.from + "T00:00:00Z") : to - defaultDays * core.DAY;
  if (!isFinite(from) || !isFinite(to)) throw s.badRequest("from and to are dates like 2026-10-01.");
  if (from > to) throw s.badRequest("from must be before to.");
  if (to - from > maxDays * core.DAY) from = to - maxDays * core.DAY;
  return [from, to];
}

/**
 * opts.answers: include item-level answers (exports yes; the Sorted feed no).
 * opts.notes: include the patient's own words.
 */
function patientRecord(app, p, fromMs, toMs, opts) {
  opts = opts || {};
  var a = s.dateValue(fromMs).string();
  var b = s.dateValue(toMs).string();
  var cks = app.findRecordsByFilter("checkins", "patient = {:p} && created >= {:a} && created <= {:b}", "created", 20000, 0, { p: p.id, a: a, b: b });
  var asg = app.findRecordsByFilter("assignments", "patient = {:p} && status = 'done' && completedAt >= {:a} && completedAt <= {:b}", "completedAt", 20000, 0, { p: p.id, a: a, b: b });
  var pending = app.findRecordsByFilter("assignments", "patient = {:p} && status = 'pending'", "", 1000, 0, { p: p.id }).length;

  var checkins = cks.map(function (r) {
    var row = { at: iso(s.toMs(r, "created")), mood: r.getInt("mood"), anxiety: r.getInt("anxiety"), sleep: r.getInt("sleep"), energy: r.getInt("energy") };
    if (opts.notes !== false) row.note = r.getString("note");
    return row;
  });

  var instruments = {};
  var defs = {};
  function inst(id) {
    if (defs[id] === undefined) {
      try {
        var rec = app.findRecordById("instruments", id);
        defs[id] = { rec: rec, def: s.readJson(rec, "definition") || {} };
      } catch (e) { defs[id] = null; }
    }
    return defs[id];
  }

  var assessments = [];
  var exercises = [];
  var rowsForFlags = [];
  asg.forEach(function (r) {
    var i = inst(r.getString("instrument"));
    if (!i) return;
    var key = i.rec.getString("key");
    var name = i.rec.getString("name");
    var at = iso(s.toMs(r, "completedAt"));
    var score = s.readJson(r, "score");
    if (i.rec.getString("kind") === "questionnaire") {
      var row = {
        at: at, key: key, name: name,
        total: score ? score.total : null, max: score ? score.max : null,
        band: score ? score.band || "" : "", severity: score ? score.severity || "none" : "none",
        flags: score && Array.isArray(score.flags) ? score.flags.map(function (f) { return { label: f.label, severity: f.severity }; }) : []
      };
      if (opts.answers) {
        var result = s.readJson(r, "result") || {};
        row.answers = result.answers || {};
        if (score && Array.isArray(score.subscales) && score.subscales.length) row.subscales = score.subscales;
        if (!instruments[key]) {
          instruments[key] = {
            name: name,
            items: (i.def.items || []).map(function (it) { return { id: it.id, text: it.text }; }),
            responseSets: i.def.responseSets || {}
          };
        }
      }
      assessments.push(row);
    } else {
      var ex = { at: at, key: key, name: name, selfStarted: r.getBool("selfStarted") };
      var res = s.readJson(r, "result") || {};
      if (res.seconds) ex.minutes = Math.round(res.seconds / 60);
      exercises.push(ex);
    }
    rowsForFlags.push({ status: "done", name: name, score: score, completedAt: s.toMs(r, "completedAt") });
  });

  var flagCheckins = cks.map(function (r) {
    return { ts: s.toMs(r, "created"), mood: r.getInt("mood"), anxiety: r.getInt("anxiety"), sleep: r.getInt("sleep"), energy: r.getInt("energy") };
  });
  var flags = core.reviewFlags(flagCheckins, rowsForFlags, Math.min(toMs, s.nowMs()));

  var connected = s.toMs(p, "wearableConsentAt") > 0;
  var days = [];
  if (connected || opts.wearableHistory) {
    var w = require(__hooks + "/lib/wearable.js");
    var tz = p.getInt("tzOffset") || 120;
    var d1 = w.localDay(fromMs, tz);
    var d2 = w.localDay(toMs, tz);
    days = app.findRecordsByFilter("biometrics", "patient = {:p} && day >= {:a} && day <= {:b}", "day", 1000, 0, { p: p.id, a: d1, b: d2 })
      .map(function (r) { return { day: r.getString("day"), values: s.readJson(r, "values") || {} }; });
  }

  var out = {
    patient: { id: p.id, name: s.displayName(p), joinedAt: iso(s.toMs(p, "created")), active: p.getBool("active") },
    from: iso(fromMs),
    to: iso(toMs),
    checkins: checkins,
    assessments: assessments,
    exercises: exercises,
    flags: flags,
    pending: pending,
    wearable: { connected: connected, days: days }
  };
  if (opts.answers) {
    out.patient.selfName = p.getString("name");
    out.instruments = instruments;
  }
  if (opts.radr && connected) {
    // the research view for the period (at most its last year), for the report
    var W = require(__hooks + "/lib/wearable.js");
    var R = require(__hooks + "/lib/radr.js");
    var D = require(__hooks + "/lib/radr_data.js");
    var tzr = p.getInt("tzOffset") || 120;
    var rTo = W.localDay(Math.min(toMs, s.nowMs()), tzr);
    var rFrom = W.localDay(Math.max(fromMs, Math.min(toMs, s.nowMs()) - 364 * core.DAY), tzr);
    if (rFrom <= rTo) out.radr = D.compact(D.forPatient(app, p, rFrom, R.addDays(rTo, 0)));
  }
  return out;
}

module.exports = { range: range, patientRecord: patientRecord, iso: iso };
