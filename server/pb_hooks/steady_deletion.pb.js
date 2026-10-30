/// <reference path="../pb_data/types.d.ts" />
// Steady 1.0.2 - deleting a patient's account. The patient asks in the app; their psychologist
// (or the master clinician) keeps what the law requires in the practice's own records and then
// deletes the account here. See lib/deletion.js.
// SPDX-License-Identifier: AGPL-3.0-or-later

// The patient asks. body: { password }
routerAdd("POST", "/api/steady/me/delete-request", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const D = require(`${__hooks}/lib/deletion.js`);
  s.requireRole(e, "patient");
  const u = $app.findRecordById("users", e.auth.id);
  if (!u.validatePassword(String(s.body(e).password || ""))) {
    throw s.badRequest("Your password isn't right.", { password: new ValidationError("wrong", "Wrong password.") });
  }
  let at = s.toMs(u, "deletionRequestedAt");
  let emailed = false;
  if (!at) {
    at = s.nowMs();
    u.set("deletionRequestedAt", s.dateValue(at));
    $app.save(u);
    s.audit($app, e, "patient.delete_request", "user:" + u.id, u.id);
    D.practiceContacts($app, u).forEach((id) => {
      s.notify($app, {
        recipient: id, kind: "system", patient: u.id, severity: "warn",
        title: "Account deletion request",
        body: s.displayName(u) + " asked to delete their Steady account. Export what belongs in your clinical records, then delete the account (on their page) within " + D.DAYS + " days."
      });
    });
    const M = require(`${__hooks}/lib/mail.js`);
    emailed = M.send($app, u.email(), "Steady: we've received your request to delete your account", [
      "Hi " + (u.getString("name") || "there") + ",",
      "",
      "We've received your request to delete your Steady account, and your practice has been told.",
      "",
      D.WHY,
      "",
      "This will be done within " + D.DAYS + " days, and you'll get an email when it is. Until then you can still use Steady.",
      "If you didn't ask for this, please contact your practice."
    ].join("\n") + M.FOOTER);
  }
  return e.json(200, { requestedAt: at, days: D.DAYS, emailed: emailed });
}, $apis.requireAuth());

// The practice deletes it: the patient's own psychologist or the master clinician, after
// confirming it's them. Only once the patient has asked, or after the account was stopped.
routerAdd("POST", "/api/steady/patients/{id}/delete-account", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const D = require(`${__hooks}/lib/deletion.js`);
  s.requireRole(e, "clinician");
  const me = e.auth;
  const p = s.findUser($app, e.request.pathValue("id"));
  if (!p || p.getString("role") !== "patient") throw new NotFoundError("Patient not found.");
  if (p.getString("clinician") !== me.id && !s.isMaster(me)) throw new NotFoundError("Patient not found.");
  require(`${__hooks}/lib/devices.js`).requireConfirmed(e, "deleting an account");
  const asked = s.toMs(p, "deletionRequestedAt");
  if (!asked && p.getBool("active")) {
    throw s.badRequest("Steady deletes an account only when the patient has asked for it, or after you've stopped their account.");
  }
  const email = p.email();
  const name = p.getString("name");
  let removed = 0;
  $app.runInTransaction((tx) => {
    s.audit(tx, e, "patient.delete", "user:" + p.id, p.id);
    removed = D.erase(tx, p.id);
  });
  let emailed = false;
  if (asked && email) {
    const M = require(`${__hooks}/lib/mail.js`);
    emailed = M.send($app, email, "Steady: your account has been deleted", [
      "Hi " + (name || "there") + ",",
      "",
      "Your Steady account has been deleted, as you asked, with everything Steady held about you.",
      "",
      "Your practice keeps the clinical records South African law requires it to (HPCSA Booklet 9), and a log of who opened your record and when."
    ].join("\n") + M.FOOTER);
  }
  return e.json(200, { deleted: true, records: removed, emailed: emailed });
}, $apis.requireAuth());
