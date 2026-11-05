/*
 * Steady - the fictional demo patients go on living, a day at a time (test servers only).
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * deploy/accounts.sh demo-patients loads Demo A, B and C with eight weeks of made-up data
 * (lib/research_demo.js). On a test server with STEADY_DEMO_DAILY=on in .env, a nightly job
 * (steady_research.pb.js) adds each new day as it would come from a real patient: last night's
 * watch summary on most days, a check-in on most evenings, and the PHQ-9 and GAD-7 on Sundays.
 * Days the server missed are filled in, up to two weeks back. Their patterns carry on: Demo A
 * stays steady, Demo B recovers and slides again, Demo C settles and has another episode.
 *
 * Only users marked demo (made by that command, never real people), and only their own records.
 * Written without hooks, as the demo command does: no notifications, nothing in the access log.
 * Keep to ES2015 for goja; use PocketBase globals only inside functions.
 */

var BACK_DAYS = 14;

function dayMs(day) { return Date.parse(day + "T00:00:00Z"); }

/** Adds the days each demo patient is missing, up to today. Returns how many days were added. */
function run(app, nowMs) {
  var s = require(__hooks + "/lib/server.js");
  var g = require(__hooks + "/lib/research_demo.js");
  var DAY = g.DAY_MS;
  var patients;
  try {
    patients = app.findRecordsByFilter("users", "demo = true && role = 'patient'", "", 50, 0);
  } catch (e) { return 0; }
  if (!patients.length) return 0;
  var inst = {};
  ["phq9", "gad7"].forEach(function (k) {
    try {
      var r = app.findFirstRecordByFilter("instruments", "key = {:k}", { k: k });
      inst[k] = { rec: r, def: s.readJson(r, "definition") };
    } catch (e) { /* not on this server: no questionnaires */ }
  });
  var db = app.unsafeWithoutHooks();
  var bio = app.findCollectionByNameOrId("biometrics");
  var cks = app.findCollectionByNameOrId("checkins");
  var asg = app.findCollectionByNameOrId("assignments");
  var newId = function () { return $security.randomStringWithAlphabet(15, "abcdefghijklmnopqrstuvwxyz0123456789"); };
  var added = 0;

  patients.forEach(function (u) {
    var key = g.profileOf(u.getString("name"));
    if (!key) return;
    var tzMin = u.getInt("tzOffset") || 120;
    var tz = tzMin * 60000;
    var watch = app.findRecordsByFilter("biometrics", "patient = {:p}", "day", 1, 0, { p: u.id });
    if (!watch.length) return; // loaded without watch data: nothing to carry on from
    var first = dayMs(watch[0].getString("day"));
    // the last day it has anything for: watch data or a check-in (some days have only one)
    var last = first;
    var lastWatch = app.findRecordsByFilter("biometrics", "patient = {:p}", "-day", 1, 0, { p: u.id });
    if (lastWatch.length) last = Math.max(last, dayMs(lastWatch[0].getString("day")));
    var lastCheck = app.findRecordsByFilter("checkins", "patient = {:p}", "-created", 1, 0, { p: u.id });
    if (lastCheck.length) last = Math.max(last, Math.floor((s.toMs(lastCheck[0], "created") + tz) / DAY) * DAY);
    var today = Math.floor((nowMs + tz) / DAY) * DAY;
    for (var d = Math.max(last + DAY, today - (BACK_DAYS - 1) * DAY); d <= today; d += DAY) {
      var i = Math.round((d - first) / DAY);
      var one = g.dayAt(key, i, d, tzMin);
      if (one.watch) {
        var has = app.findRecordsByFilter("biometrics", "patient = {:p} && day = {:d}", "", 1, 0, { p: u.id, d: one.watch.day });
        if (!has.length) {
          var b = new Record(bio);
          b.set("id", newId());
          var bat = s.dateValue(Date.parse(one.watch.day + "T06:00:00Z"));
          b.setRaw("created", bat);
          b.setRaw("updated", bat);
          b.set("patient", u.id);
          b.set("day", one.watch.day);
          b.set("values", one.watch.values);
          b.set("platform", "android");
          b.set("source", "Steady demo data");
          b.set("algorithm", "demo");
          db.save(b);
        }
      }
      // a check-in only once its evening has come
      if (one.checkin && one.checkin.at <= nowMs) {
        var c = new Record(cks);
        c.set("id", newId());
        c.set("patient", u.id);
        ["mood", "anxiety", "sleep", "energy"].forEach(function (k) { c.set(k, one.checkin[k]); });
        c.set("note", one.checkin.note);
        c.setRaw("created", s.dateValue(one.checkin.at));
        c.setRaw("updated", s.dateValue(one.checkin.at));
        db.save(c);
      }
      one.questionnaires.forEach(function (q) {
        var it = inst[q.key];
        if (!it || q.at > nowMs) return;
        var a = new Record(asg);
        a.set("id", newId());
        a.set("patient", u.id);
        a.set("clinician", u.getString("clinician"));
        a.set("instrument", it.rec.id);
        a.set("status", "done");
        a.set("repeat", "once");
        a.set("note", "Demo data");
        a.set("result", { answers: q.answers, version: it.def.version || "1" });
        a.set("score", s.core.scoreAnswers(it.def, q.answers));
        a.set("completedAt", s.dateValue(q.at));
        a.setRaw("created", s.dateValue(q.at - 2 * 3600000));
        a.setRaw("updated", s.dateValue(q.at));
        db.save(a);
      });
      added++;
    }
  });
  return added;
}

module.exports = { run: run, BACK_DAYS: BACK_DAYS };
