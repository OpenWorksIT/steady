/// <reference path="../pb_data/types.d.ts" />
// Steady - initial schema and access rules.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Access model
//   patient   : sees and writes only their own check-ins; sees their own assignments;
//               completes assignments through /api/steady routes (scored on the server).
//   clinician : sees patients linked to them and those patients' data; creates assignments
//               for their own patients; manages instruments.
//   superuser : PocketBase admin (OpenWorks / practice IT). Creates clinician accounts.
// Mutations that need checks beyond a rule (scoring, invites, licence gates) go through
// the routes in pb_hooks/steady.pb.js.

migrate((app) => {
  const users = app.findCollectionByNameOrId("users");

  users.fields.add(new SelectField({ name: "role", values: ["patient", "clinician"], maxSelect: 1, required: true }));
  users.fields.add(new RelationField({ name: "clinician", collectionId: users.id, maxSelect: 1, cascadeDelete: false }));
  users.fields.add(new BoolField({ name: "active" }));
  users.fields.add(new DateField({ name: "consentAt" }));
  users.fields.add(new TextField({ name: "consentVersion", max: 40 }));
  users.fields.add(new NumberField({ name: "tzOffset", min: -720, max: 840, onlyInt: true }));

  // Nobody signs up on their own: clinicians are created by a superuser, patients join with an invite code.
  users.createRule = null;
  // Deactivated accounts can't sign in. Remember to tick "active" when creating a clinician.
  users.authRule = "active = true";
  users.listRule = "id = @request.auth.id || id = @request.auth.clinician || (@request.auth.role = 'clinician' && clinician = @request.auth.id)";
  users.viewRule = users.listRule;
  users.updateRule = "id = @request.auth.id && @request.body.role:isset = false && @request.body.clinician:isset = false && @request.body.active:isset = false && @request.body.consentAt:isset = false";
  users.deleteRule = null;
  app.save(users);

  const autodates = [
    { name: "created", type: "autodate", onCreate: true, onUpdate: false },
    { name: "updated", type: "autodate", onCreate: true, onUpdate: true }
  ];

  const instruments = new Collection({
    type: "base",
    name: "instruments",
    fields: [
      { name: "key", type: "text", required: true, max: 60, pattern: "^[a-z0-9][a-z0-9_-]{1,59}$" },
      { name: "name", type: "text", required: true, max: 80 },
      { name: "kind", type: "select", values: ["questionnaire", "exercise"], maxSelect: 1, required: true },
      { name: "definition", type: "json", required: true, maxSize: 200000 },
      { name: "licenceStatus", type: "select", values: ["cleared", "review", "blocked", "custom"], maxSelect: 1, required: true },
      { name: "licenceConfirmedBy", type: "relation", collectionId: users.id, maxSelect: 1 },
      { name: "licenceConfirmedAt", type: "date" },
      { name: "builtin", type: "bool" },
      { name: "active", type: "bool" },
      { name: "createdBy", type: "relation", collectionId: users.id, maxSelect: 1 }
    ].concat(autodates),
    indexes: ["CREATE UNIQUE INDEX idx_instruments_key ON instruments (key)"],
    listRule: "@request.auth.id != ''",
    viewRule: "@request.auth.id != ''",
    // created and edited through /api/steady/instruments so definitions are always validated
    createRule: null,
    updateRule: null,
    deleteRule: null
  });
  app.save(instruments);

  const assignments = new Collection({
    type: "base",
    name: "assignments",
    fields: [
      { name: "patient", type: "relation", collectionId: users.id, maxSelect: 1, required: true, cascadeDelete: true },
      { name: "clinician", type: "relation", collectionId: users.id, maxSelect: 1, required: true },
      { name: "instrument", type: "relation", collectionId: instruments.id, maxSelect: 1, required: true },
      { name: "status", type: "select", values: ["pending", "done", "cancelled"], maxSelect: 1, required: true },
      { name: "note", type: "text", max: 280 },
      { name: "repeat", type: "select", values: ["once", "daily", "weekly"], maxSelect: 1 },
      { name: "availableFrom", type: "date" },
      { name: "completedAt", type: "date" },
      { name: "selfStarted", type: "bool" },
      { name: "result", type: "json", maxSize: 100000 },
      { name: "score", type: "json", maxSize: 20000 }
    ].concat(autodates),
    indexes: [
      "CREATE INDEX idx_assignments_patient ON assignments (patient, status)",
      "CREATE INDEX idx_assignments_clinician ON assignments (clinician, status)"
    ],
    listRule: "patient = @request.auth.id || clinician = @request.auth.id",
    viewRule: "patient = @request.auth.id || clinician = @request.auth.id",
    // further checks (patient belongs to clinician, instrument licence) in onRecordCreateRequest
    createRule: "@request.auth.role = 'clinician' && @request.body.clinician = @request.auth.id",
    updateRule: null,
    deleteRule: null
  });
  app.save(assignments);

  const checkins = new Collection({
    type: "base",
    name: "checkins",
    fields: [
      { name: "patient", type: "relation", collectionId: users.id, maxSelect: 1, required: true, cascadeDelete: true },
      { name: "mood", type: "number", min: 1, max: 5, onlyInt: true, required: true },
      { name: "anxiety", type: "number", min: 1, max: 5, onlyInt: true, required: true },
      { name: "sleep", type: "number", min: 1, max: 5, onlyInt: true, required: true },
      { name: "energy", type: "number", min: 1, max: 5, onlyInt: true, required: true },
      { name: "note", type: "text", max: 1000 }
    ].concat(autodates),
    indexes: ["CREATE INDEX idx_checkins_patient ON checkins (patient, created)"],
    listRule: "patient = @request.auth.id || patient.clinician = @request.auth.id",
    viewRule: "patient = @request.auth.id || patient.clinician = @request.auth.id",
    createRule: "@request.auth.role = 'patient' && @request.body.patient = @request.auth.id",
    updateRule: null,
    deleteRule: null
  });
  app.save(checkins);

  const notifications = new Collection({
    type: "base",
    name: "notifications",
    fields: [
      { name: "recipient", type: "relation", collectionId: users.id, maxSelect: 1, required: true, cascadeDelete: true },
      { name: "kind", type: "select", values: ["checkin", "completed", "assigned", "system"], maxSelect: 1, required: true },
      { name: "patient", type: "relation", collectionId: users.id, maxSelect: 1 },
      { name: "assignment", type: "relation", collectionId: assignments.id, maxSelect: 1 },
      { name: "title", type: "text", max: 160 },
      { name: "body", type: "text", max: 400 },
      { name: "severity", type: "select", values: ["none", "info", "warn", "alert"], maxSelect: 1 },
      { name: "read", type: "bool" }
    ].concat(autodates),
    indexes: ["CREATE INDEX idx_notifications_recipient ON notifications (recipient, read, created)"],
    listRule: "recipient = @request.auth.id",
    viewRule: "recipient = @request.auth.id",
    createRule: null,
    updateRule: "recipient = @request.auth.id && @request.body.recipient:isset = false && @request.body.title:isset = false && @request.body.body:isset = false",
    deleteRule: "recipient = @request.auth.id"
  });
  app.save(notifications);

  const devices = new Collection({
    type: "base",
    name: "devices",
    fields: [
      { name: "user", type: "relation", collectionId: users.id, maxSelect: 1, required: true, cascadeDelete: true },
      { name: "platform", type: "select", values: ["ios", "android"], maxSelect: 1, required: true },
      { name: "provider", type: "select", values: ["apns", "fcm", "unifiedpush"], maxSelect: 1, required: true },
      { name: "token", type: "text", required: true, max: 2000 },
      { name: "sandbox", type: "bool" }
    ].concat(autodates),
    indexes: ["CREATE UNIQUE INDEX idx_devices_token ON devices (token)"],
    listRule: "user = @request.auth.id",
    viewRule: "user = @request.auth.id",
    createRule: "@request.auth.id != '' && @request.body.user = @request.auth.id",
    updateRule: "user = @request.auth.id && @request.body.user:isset = false",
    deleteRule: "user = @request.auth.id"
  });
  app.save(devices);

  const invites = new Collection({
    type: "base",
    name: "invites",
    fields: [
      { name: "code", type: "text", required: true, min: 8, max: 8 },
      { name: "clinician", type: "relation", collectionId: users.id, maxSelect: 1, required: true, cascadeDelete: true },
      { name: "label", type: "text", max: 80 },
      { name: "expiresAt", type: "date", required: true },
      { name: "usedBy", type: "relation", collectionId: users.id, maxSelect: 1 },
      { name: "usedAt", type: "date" }
    ].concat(autodates),
    indexes: ["CREATE UNIQUE INDEX idx_invites_code ON invites (code)"],
    listRule: "clinician = @request.auth.id",
    viewRule: "clinician = @request.auth.id",
    createRule: null,
    updateRule: null,
    deleteRule: "clinician = @request.auth.id && usedBy = ''"
  });
  app.save(invites);

  const audit = new Collection({
    type: "base",
    name: "auditlog",
    fields: [
      { name: "actor", type: "relation", collectionId: users.id, maxSelect: 1 },
      { name: "action", type: "text", required: true, max: 60 },
      { name: "target", type: "text", max: 200 },
      { name: "patient", type: "relation", collectionId: users.id, maxSelect: 1 },
      { name: "ip", type: "text", max: 64 }
    ].concat(autodates),
    indexes: ["CREATE INDEX idx_audit_patient ON auditlog (patient, created)"],
    // superusers only
    listRule: null,
    viewRule: null,
    createRule: null,
    updateRule: null,
    deleteRule: null
  });
  app.save(audit);
}, (app) => {
  for (const name of ["auditlog", "invites", "devices", "notifications", "checkins", "assignments", "instruments"]) {
    try { app.delete(app.findCollectionByNameOrId(name)); } catch (_) { /* already gone */ }
  }
  const users = app.findCollectionByNameOrId("users");
  for (const f of ["role", "clinician", "active", "consentAt", "consentVersion", "tzOffset"]) users.fields.removeByName(f);
  users.createRule = "";
  app.save(users);
});
