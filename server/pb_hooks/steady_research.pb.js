/// <reference path="../pb_data/types.d.ts" />
// Steady - RADR for psychologists: the RADR tab, each number explained, flags marked as
// reviewed; and the fictional demo patients that OpenWorks loads with deploy/accounts.sh
// demo-patients.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// RADR (lib/radr.js, docs/RADR.md) shows how far a patient's watch data and check-ins are from
// their own normal, to improve care: not a risk score, prediction or diagnosis. It orders the
// psychologist's list and never raises an alert. Only staff who may see the patient use these
// routes (their psychologist, or a colleague it's shared with); every read is access-logged
// before the answer goes out, and refused if it can't be.

// The patient's RADR for the last `days` days (default 56, at most 365), with the flags on the
// latest day and who marked each as reviewed.
routerAdd("GET", "/api/steady/patients/{id}/radr", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const w = require(`${__hooks}/lib/wearable.js`);
  const R = require(`${__hooks}/lib/radr.js`);
  const D = require(`${__hooks}/lib/radr_data.js`);
  s.requireRole(e, "clinician");
  const v = s.viewablePatient($app, e.auth.id, e.request.pathValue("id"));
  const p = v.patient;
  const q = e.requestInfo().query || {};
  const days = Math.max(14, Math.min(365, Number(q.days) || 56));
  const tz = p.getInt("tzOffset") || 120;
  const to = w.localDay(s.nowMs(), tz);
  const from = R.addDays(to, -(days - 1));
  const out = D.forPatient($app, p, from, to);
  out.flags = D.current($app, p).flags;
  s.audit($app, e, "patient.radr", "user:" + p.id + " " + from + ".." + to + (v.own ? "" : " shared"), p.id, true);
  return e.json(200, out);
}, $apis.requireAuth());

// One day explained (default: the latest rated day): in plain words, what was measured, the
// person's usual range, the value then, how far from usual and why that counts, with the days
// and values behind each number. On the latest day, its flags and their reviews too.
routerAdd("GET", "/api/steady/patients/{id}/radr/explain", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const w = require(`${__hooks}/lib/wearable.js`);
  const D = require(`${__hooks}/lib/radr_data.js`);
  s.requireRole(e, "clinician");
  const v = s.viewablePatient($app, e.auth.id, e.request.pathValue("id"));
  const p = v.patient;
  const q = e.requestInfo().query || {};
  const today = w.localDay(s.nowMs(), p.getInt("tzOffset") || 120);
  const asked = String(q.day || "");
  if (asked && (!w.validDay(asked) || asked > today || asked < w.addDays(today, -400))) {
    throw s.badRequest("day must be a date like 2026-11-02, in the last 400 days.");
  }
  // logged before anything is read: if the access log can't be written, nothing is shown
  s.audit($app, e, "patient.radr.explain", "user:" + p.id + (asked ? " " + asked : "") + (v.own ? "" : " shared"), p.id, true);
  const cur = D.current($app, p);
  const latest = cur.latest ? cur.latest.day : null;
  const day = asked || latest || today;
  const out = D.explain($app, p, day);
  out.latestDay = latest;
  out.flags = day === latest ? cur.flags : [];
  return e.json(200, out);
}, $apis.requireAuth());

// Marks one flag on the latest day as reviewed (body: { key, note }): who and when. The flag
// stays visible with that, and no longer moves the patient up the list until something new
// appears. The patient's own psychologist or a colleague it's shared with.
routerAdd("POST", "/api/steady/patients/{id}/radr/review", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const D = require(`${__hooks}/lib/radr_data.js`);
  s.requireRole(e, "clinician");
  const v = s.viewablePatient($app, e.auth.id, e.request.pathValue("id"));
  const p = v.patient;
  const b = s.body(e);
  const key = s.core.str(b.key, 80);
  if (!/^radr:(sleep|circadian|activity|cardiac):\d{4}-\d{2}-\d{2}$/.test(key)) throw s.badRequest("This can't be marked as reviewed.");
  // logged first: it reads the patient's data, and if the log can't be written nothing changes
  s.audit($app, e, "patient.radr.review", "radr" + (v.own ? "" : " shared"), p.id, true);
  const flag = D.current($app, p).flags.filter((f) => f.key === key)[0];
  if (!flag) throw s.badRequest("This has changed since you opened it. Pull down to refresh, then look again.");
  const reviewed = D.markReviewed($app, p, flag, e.auth, s.core.str(b.note, 500));
  D.refreshLatest($app, p);
  return e.json(200, { key: key, reviewed: reviewed });
}, $apis.requireAuth());

// Load (or remove) the three fictional demo patients for one psychologist. Terminal only.
routerAdd("POST", "/api/steady/ops/demo", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const x = require(`${__hooks}/lib/practice.js`);
  const g = require(`${__hooks}/lib/research_demo.js`);
  x.opsGuard(e);
  const b = s.body(e);
  let c = null;
  try { c = $app.findAuthRecordByEmail("users", s.core.str(b.clinician, 200).toLowerCase()); } catch (_) { c = null; }
  if (!c || c.getString("role") !== "clinician") throw new NotFoundError("No psychologist with that email.");

  const db = $app.unsafeWithoutHooks();
  const existing = $app.findRecordsByFilter("users", "demo = true && clinician = {:c}", "", 100, 0, { c: c.id });
  // with hooks, so their check-ins, results and watch data go too (cascade)
  existing.forEach((u) => $app.delete(u));
  if (b.remove === true) {
    s.audit($app, null, "ops.demo.remove", "clinician:" + c.id + " count:" + existing.length, "");
    return e.json(200, { removed: existing.length, created: [] });
  }

  const inst = {};
  ["phq9", "gad7"].forEach((k) => {
    const r = $app.findFirstRecordByFilter("instruments", "key = {:k}", { k: k });
    inst[k] = { rec: r, def: s.readJson(r, "definition") };
  });
  const tz = 120;
  const users = $app.findCollectionByNameOrId("users");
  const bio = $app.findCollectionByNameOrId("biometrics");
  const cks = $app.findCollectionByNameOrId("checkins");
  const asg = $app.findCollectionByNameOrId("assignments");
  const created = [];
  // without hooks, PocketBase doesn't fill in ids or timestamps: set them here
  const newId = () => $security.randomStringWithAlphabet(15, "abcdefghijklmnopqrstuvwxyz0123456789");
  g.generate(s.nowMs(), tz).forEach((p) => {
    const first = p.checkins.length ? p.checkins[0].at : s.nowMs() - g.DAYS * s.core.DAY;
    const u = new Record(users);
    u.set("id", newId());
    u.setEmail("demo-" + p.key + "-" + $security.randomStringWithAlphabet(6, "abcdefghijkmnpqrstuvwxyz23456789") + "@demo.steady.invalid");
    u.setRandomPassword();
    u.setVerified(false);
    u.set("name", p.selfName);
    u.set("clinicianLabel", p.label);
    u.set("role", "patient");
    u.set("clinician", c.id);
    u.set("active", true);
    u.set("demo", true);
    u.set("tzOffset", tz);
    u.set("consentAt", s.dateValue(first - s.core.DAY));
    u.set("consentVersion", "demo");
    u.set("wearableConsentAt", s.dateValue(first - s.core.DAY));
    u.set("wearableConsentVersion", "demo");
    u.setRaw("created", s.dateValue(first - s.core.DAY));
    u.setRaw("updated", s.dateValue(first - s.core.DAY));
    db.save(u);

    p.days.forEach((d) => {
      const r = new Record(bio);
      r.set("id", newId());
      const at = s.dateValue(Date.parse(d.day + "T06:00:00Z"));
      r.setRaw("created", at);
      r.setRaw("updated", at);
      r.set("patient", u.id);
      r.set("day", d.day);
      r.set("values", d.values);
      r.set("platform", "android");
      r.set("source", "Steady demo data");
      r.set("algorithm", "demo");
      db.save(r);
    });
    p.checkins.forEach((ck) => {
      const r = new Record(cks);
      r.set("id", newId());
      r.set("patient", u.id);
      ["mood", "anxiety", "sleep", "energy"].forEach((k) => r.set(k, ck[k]));
      r.set("note", ck.note);
      r.setRaw("created", s.dateValue(ck.at));
      r.setRaw("updated", s.dateValue(ck.at));
      db.save(r);
    });
    p.questionnaires.forEach((qq) => {
      const i = inst[qq.key];
      const r = new Record(asg);
      r.set("id", newId());
      r.set("patient", u.id);
      r.set("clinician", c.id);
      r.set("instrument", i.rec.id);
      r.set("status", "done");
      r.set("repeat", "once");
      r.set("note", "Demo data");
      r.set("result", { answers: qq.answers, version: i.def.version || "1" });
      r.set("score", s.core.scoreAnswers(i.def, qq.answers));
      r.set("completedAt", s.dateValue(qq.at));
      r.setRaw("created", s.dateValue(qq.at - 2 * 3600000));
      r.setRaw("updated", s.dateValue(qq.at));
      db.save(r);
    });
    created.push({ id: u.id, name: p.label, summary: p.summary, days: p.days.length, checkins: p.checkins.length, questionnaires: p.questionnaires.length });
  });
  s.audit($app, null, "ops.demo.create", "clinician:" + c.id + " count:" + created.length, "");
  return e.json(200, { removed: existing.length, created: created });
});
