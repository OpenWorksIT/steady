/// <reference path="../pb_data/types.d.ts" />
// Steady 1.0 - looking after each patient's place in the psychologist's work:
//   users.careStatus     "" (seeing them), "stable" (doing well: bottom of the list, no
//                        highlighting) or "archived" (no longer seeing them: off the list)
//   users.radrExclusions RADR domains the psychologist switched off for this patient, with when,
//                        who and why (e.g. sleep for a shift worker)
//   users.radrLatest     the patient's latest RADR day, kept for ordering the list
//   users.lastNote       the newest clinician note, for the list
//   users.appBuild/appPlatform/appSeenAt  the app version this person last used
//   users.healthPerm     whether the phone still lets Steady read watch data
//   notes                the psychologist's short dated notes on a patient (never shown to them)
//   flagreviews          flags a psychologist has marked as reviewed, with an optional note
// The care fields are hidden: a patient can read their own account record, and must never see
// their psychologist's notes or settings. Only the routes read them.
// All written through /api/steady routes only; the collections have no API rules.
// SPDX-License-Identifier: AGPL-3.0-or-later

const CARE_FIELDS = ["careStatus", "careStatusAt", "radrExclusions", "radrLatest", "lastNote", "appBuild", "appPlatform", "appSeenAt", "healthPerm"];

migrate((app) => {
  const users = app.findCollectionByNameOrId("users");
  users.fields.add(new SelectField({ name: "careStatus", maxSelect: 1, values: ["stable", "archived"], hidden: true }));
  users.fields.add(new DateField({ name: "careStatusAt", hidden: true }));
  users.fields.add(new JSONField({ name: "radrExclusions", maxSize: 4000, hidden: true }));
  users.fields.add(new JSONField({ name: "radrLatest", maxSize: 4000, hidden: true }));
  users.fields.add(new JSONField({ name: "lastNote", maxSize: 2000, hidden: true }));
  users.fields.add(new TextField({ name: "appBuild", max: 40 }));
  users.fields.add(new TextField({ name: "appPlatform", max: 20 }));
  users.fields.add(new DateField({ name: "appSeenAt" }));
  users.fields.add(new JSONField({ name: "healthPerm", maxSize: 1000 }));
  // nobody sets these through the REST API, only through the routes
  const rule = users.updateRule === null || users.updateRule === undefined ? null : String(users.updateRule);
  if (rule !== null && rule.indexOf("careStatus") < 0) {
    users.updateRule = rule + CARE_FIELDS.map((f) => " && @request.body." + f + ":isset = false").join("");
  }
  app.save(users);

  app.save(new Collection({
    type: "base",
    name: "notes",
    fields: [
      { name: "patient", type: "relation", collectionId: users.id, maxSelect: 1, required: true, cascadeDelete: true },
      { name: "author", type: "relation", collectionId: users.id, maxSelect: 1, cascadeDelete: false },
      { name: "authorName", type: "text", max: 120 },
      { name: "text", type: "text", max: 2000, required: true },
      { name: "created", type: "autodate", onCreate: true, onUpdate: false }
    ],
    indexes: ["CREATE INDEX `idx_notes_patient` ON `notes` (`patient`, `created`)"],
    listRule: null, viewRule: null, createRule: null, updateRule: null, deleteRule: null
  }));

  app.save(new Collection({
    type: "base",
    name: "flagreviews",
    fields: [
      { name: "patient", type: "relation", collectionId: users.id, maxSelect: 1, required: true, cascadeDelete: true },
      { name: "key", type: "text", max: 160, required: true },
      { name: "reviewer", type: "relation", collectionId: users.id, maxSelect: 1, cascadeDelete: false },
      { name: "reviewerName", type: "text", max: 120 },
      { name: "note", type: "text", max: 500 },
      { name: "created", type: "autodate", onCreate: true, onUpdate: false }
    ],
    indexes: ["CREATE UNIQUE INDEX `idx_flagreviews_key` ON `flagreviews` (`patient`, `key`)"],
    listRule: null, viewRule: null, createRule: null, updateRule: null, deleteRule: null
  }));
}, (app) => {
  ["notes", "flagreviews"].forEach((n) => { try { app.delete(app.findCollectionByNameOrId(n)); } catch (_) { /* gone */ } });
  const users = app.findCollectionByNameOrId("users");
  CARE_FIELDS.forEach((f) => users.fields.removeByName(f));
  const rule = users.updateRule === null || users.updateRule === undefined ? null : String(users.updateRule);
  if (rule !== null) users.updateRule = CARE_FIELDS.reduce((r, f) => r.split(" && @request.body." + f + ":isset = false").join(""), rule);
  app.save(users);
});
