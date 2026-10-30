/// <reference path="../pb_data/types.d.ts" />
// Steady - the psychologist looking after each patient: short notes, flags marked as
// reviewed, archiving, "stable, ease off", and RADR measures switched off for one patient.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Same rules as steady.pb.js: require() inside handlers, ES2015 only. Notes and settings are
// the psychologist's own: never shown to the patient. Colleagues a patient is shared with can
// read notes; only the patient's own psychologist changes anything.

/* ---------- notes ---------- */

routerAdd("GET", "/api/steady/patients/{id}/notes", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireRole(e, "clinician");
  const v = s.viewablePatient($app, e.auth.id, e.request.pathValue("id"));
  const p = v.patient;
  const notes = $app.findRecordsByFilter("notes", "patient = {:p}", "-created", 500, 0, { p: p.id }).map((n) => ({
    id: n.id, text: n.getString("text"), by: n.getString("authorName"), at: s.toMs(n, "created")
  }));
  s.audit($app, e, "patient.notes", "user:" + p.id + (v.own ? "" : " shared"), p.id);
  return e.json(200, { notes: notes });
}, $apis.requireAuth());

routerAdd("POST", "/api/steady/patients/{id}/notes", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const c = require(`${__hooks}/lib/care.js`);
  s.requireRole(e, "clinician");
  const p = s.ownPatient($app, e.auth.id, e.request.pathValue("id"));
  const n = c.addNote($app, p, e.auth, s.body(e).text);
  s.audit($app, e, "patient.note.add", "note:" + n.id, p.id);
  return e.json(200, { id: n.id, text: n.getString("text"), by: n.getString("authorName"), at: s.toMs(n, "created") });
}, $apis.requireAuth());

/* ---------- where the patient is in the psychologist's work ---------- */

// status: "" (seeing them), "stable" (doing well: bottom of the list, nothing highlighted) or
// "archived" (no longer seeing them: off the list; their account still works).
routerAdd("POST", "/api/steady/patients/{id}/care", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireRole(e, "clinician");
  const p = s.ownPatient($app, e.auth.id, e.request.pathValue("id"));
  const status = String(s.body(e).status || "");
  if (["", "stable", "archived"].indexOf(status) < 0) throw s.badRequest("status must be '', 'stable' or 'archived'.");
  p.set("careStatus", status);
  p.set("careStatusAt", status ? new DateTime() : "");
  $app.unsafeWithoutHooks().save(p);
  s.audit($app, e, "patient.care." + (status || "active"), "user:" + p.id, p.id);
  return e.json(200, { id: p.id, careStatus: status });
}, $apis.requireAuth());

// The psychologist's archived patients, to bring someone back (Settings > Archived patients).
routerAdd("GET", "/api/steady/patients-archived", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireRole(e, "clinician");
  const list = $app.findRecordsByFilter("users", "role = 'patient' && clinician = {:c} && careStatus = 'archived'", "name", 5000, 0, { c: e.auth.id })
    .map((p) => ({ id: p.id, name: s.displayName(p), archivedAt: s.toMs(p, "careStatusAt"), active: p.getBool("active") }));
  return e.json(200, { patients: list });
}, $apis.requireAuth());

/* ---------- RADR measures for this patient ---------- */

// Switch a RADR domain off (or back on) for one patient, e.g. sleep for a shift worker. The
// data is still collected and shown; it just isn't counted in their RADR. Dated, with who and why.
routerAdd("POST", "/api/steady/patients/{id}/radr-exclusions", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const R = require(`${__hooks}/lib/radr.js`);
  const D = require(`${__hooks}/lib/radr_data.js`);
  s.requireRole(e, "clinician");
  const p = s.ownPatient($app, e.auth.id, e.request.pathValue("id"));
  const b = s.body(e);
  const domain = String(b.domain || "");
  if (R.DOMAINS.indexOf(domain) < 0) throw s.badRequest("domain must be one of " + R.DOMAINS.join(", ") + ".");
  const reason = s.core.str(b.reason, 200);
  let list = D.exclusions(p).filter((x) => x.domain !== domain);
  if (b.excluded === true) {
    if (!reason) throw s.badRequest("Say briefly why, e.g. 'shift worker'. It shows wherever RADR does.");
    list.push({ domain: domain, since: new Date(s.nowMs()).toISOString(), by: e.auth.getString("name"), reason: reason });
  }
  p.set("radrExclusions", list);
  $app.unsafeWithoutHooks().save(p);
  D.refreshLatest($app, p);
  s.audit($app, e, "patient.radr." + (b.excluded === true ? "exclude" : "include"), domain + (reason ? " (" + reason + ")" : ""), p.id);
  return e.json(200, { exclusions: list });
}, $apis.requireAuth());

/* ---------- flags marked as reviewed ---------- */

// body: { key, label, note }. The flag stays visible with who reviewed it and when, and no
// longer moves the patient up the list. A note is also kept with the patient's notes.
routerAdd("POST", "/api/steady/patients/{id}/flags/review", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const c = require(`${__hooks}/lib/care.js`);
  s.requireRole(e, "clinician");
  const p = s.ownPatient($app, e.auth.id, e.request.pathValue("id"));
  const b = s.body(e);
  const key = s.core.str(b.key, 160);
  if (!/^(a:|lowmood:)/.test(key)) throw s.badRequest("This flag can't be marked as reviewed.");
  const note = s.core.str(b.note, 500);
  let r = null;
  try { r = $app.findFirstRecordByFilter("flagreviews", "patient = {:p} && key = {:k}", { p: p.id, k: key }); } catch (_) { r = null; }
  if (!r) {
    r = new Record($app.findCollectionByNameOrId("flagreviews"));
    r.set("patient", p.id);
    r.set("key", key);
  }
  r.set("reviewer", e.auth.id);
  r.set("reviewerName", e.auth.getString("name"));
  r.set("note", note);
  $app.save(r);
  if (note) c.addNote($app, p, e.auth, "Reviewed " + (s.core.str(b.label, 160) || "a flag") + ": " + note);
  s.audit($app, e, "patient.flag.review", key, p.id);
  return e.json(200, { key: key, reviewed: { by: e.auth.getString("name"), at: s.nowMs(), note: note } });
}, $apis.requireAuth());

/* ---------- keeping each patient's latest RADR day for the list ---------- */

// 03:15 UTC: watch data that stopped arriving should stop counting.
cronAdd("steady_radr_latest", "15 3 * * *", () => {
  const D = require(`${__hooks}/lib/radr_data.js`);
  $app.findRecordsByFilter("users", "role = 'patient' && active = true && wearableConsentAt != ''", "", 50000, 0).forEach((p) => {
    try { D.refreshLatest($app, p); } catch (err) { $app.logger().warn("steady: radr refresh failed", "user", p.id, "error", String(err)); }
  });
});
