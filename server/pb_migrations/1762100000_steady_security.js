/// <reference path="../pb_data/types.d.ts" />
// Steady 1.0.4 - from the November 2026 security review.
//   signinfails            wrong-try counts per email address (lib/signin.js), counted before
//                          each check so tries sent at once can't slip under the limit, and kept
//                          for unknown addresses too so the answers don't reveal who has an account
//   auditlog.patientRef    the patient's id as plain text: the patient relation is emptied when
//                          the account is deleted, and the log of who opened the record must stay
//                          findable afterwards
//   users / _superusers    PocketBase's own "login from a new location" emails off (Steady sends
//                          its own notices; PocketBase's would go out unbranded, or not at all)
//   users.updateRule       passwords change only through /api/steady/me/password (which checks
//                          the old one, emails a notice and writes the access log)
//   instruments            patients read built-in instruments and the ones sent to them, not
//                          every custom one a psychologist in the practice has written
// SPDX-License-Identifier: AGPL-3.0-or-later

const NO_PASSWORD = " && @request.body.password:isset = false && @request.body.oldPassword:isset = false && @request.body.passwordConfirm:isset = false";
const ANYONE = "@request.auth.id != ''";
const INSTRUMENT_READ = "(builtin = true || @request.auth.role = 'clinician' || assignments_via_instrument.patient ?= @request.auth.id)";

function str(v) { return v === null || v === undefined ? null : String(v); }

migrate((app) => {
  const fails = new Collection({
    type: "base",
    name: "signinfails",
    fields: [
      { name: "key", type: "text", required: true, max: 80 },
      { name: "n", type: "number" },
      { name: "first", type: "number" },
      { name: "until", type: "number" }
    ],
    indexes: ["CREATE UNIQUE INDEX idx_signinfails_key ON signinfails (key)"],
    listRule: null, viewRule: null, createRule: null, updateRule: null, deleteRule: null
  });
  app.save(fails);

  const audit = app.findCollectionByNameOrId("auditlog");
  audit.fields.add(new TextField({ name: "patientRef", max: 15 }));
  audit.indexes = (audit.indexes || []).concat(["CREATE INDEX idx_audit_patientref ON auditlog (patientRef, created)"]);
  app.save(audit);
  app.db().newQuery("UPDATE auditlog SET patientRef = patient WHERE patient != '' AND (patientRef = '' OR patientRef IS NULL)").execute();

  ["users", "_superusers"].forEach((name) => {
    let c = null;
    try { c = app.findCollectionByNameOrId(name); } catch (_) { return; }
    if (c.authAlert) c.authAlert.enabled = false;
    if (name === "users") {
      const rule = str(c.updateRule);
      if (rule !== null && rule.indexOf("@request.body.password:isset") < 0) c.updateRule = rule + NO_PASSWORD;
    }
    app.save(c);
  });

  const inst = app.findCollectionByNameOrId("instruments");
  ["listRule", "viewRule"].forEach((r) => {
    const rule = str(inst[r]);
    if (rule !== null && rule.indexOf(ANYONE) >= 0 && rule.indexOf("assignments_via_instrument") < 0) inst[r] = rule.split(ANYONE).join(INSTRUMENT_READ);
  });
  app.save(inst);
}, (app) => {
  try { app.delete(app.findCollectionByNameOrId("signinfails")); } catch (_) { /* gone */ }
  const audit = app.findCollectionByNameOrId("auditlog");
  audit.fields.removeByName("patientRef");
  audit.indexes = (audit.indexes || []).filter((i) => i.indexOf("idx_audit_patientref") < 0);
  app.save(audit);
  const users = app.findCollectionByNameOrId("users");
  const rule = str(users.updateRule);
  if (rule !== null) users.updateRule = rule.split(NO_PASSWORD).join("");
  app.save(users);
  const inst = app.findCollectionByNameOrId("instruments");
  ["listRule", "viewRule"].forEach((r) => {
    const rule = str(inst[r]);
    if (rule !== null) inst[r] = rule.split(INSTRUMENT_READ).join(ANYONE);
  });
  app.save(inst);
});
