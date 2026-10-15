/// <reference path="../pb_data/types.d.ts" />
// Steady - wearable daily summaries and consent records.
// SPDX-License-Identifier: AGPL-3.0-or-later

migrate((app) => {
  const users = app.findCollectionByNameOrId("users");
  users.fields.add(new DateField({ name: "privacyNoticeAt" }));
  users.fields.add(new TextField({ name: "privacyNoticeVersion", max: 40 }));
  users.fields.add(new DateField({ name: "wearableConsentAt" }));
  users.fields.add(new TextField({ name: "wearableConsentVersion", max: 40 }));
  // consent and acknowledgement fields are only set through /api/steady/consent
  users.updateRule = "id = @request.auth.id && @request.body.role:isset = false && @request.body.clinician:isset = false && @request.body.active:isset = false && @request.body.consentAt:isset = false" +
    " && @request.body.privacyNoticeAt:isset = false && @request.body.privacyNoticeVersion:isset = false" +
    " && @request.body.wearableConsentAt:isset = false && @request.body.wearableConsentVersion:isset = false";
  app.save(users);

  const biometrics = new Collection({
    type: "base",
    name: "biometrics",
    fields: [
      { name: "patient", type: "relation", collectionId: users.id, maxSelect: 1, required: true, cascadeDelete: true },
      // the patient's local date, YYYY-MM-DD
      { name: "day", type: "text", required: true, min: 10, max: 10, pattern: "^\\d{4}-\\d{2}-\\d{2}$" },
      { name: "values", type: "json", maxSize: 5000 },
      { name: "platform", type: "select", values: ["android", "ios"], maxSelect: 1 },
      { name: "source", type: "text", max: 80 },
      { name: "algorithm", type: "text", max: 20 },
      { name: "created", type: "autodate", onCreate: true, onUpdate: false },
      { name: "updated", type: "autodate", onCreate: true, onUpdate: true }
    ],
    indexes: ["CREATE UNIQUE INDEX idx_biometrics_patient_day ON biometrics (patient, day)"],
    listRule: "patient = @request.auth.id || patient.clinician = @request.auth.id",
    viewRule: "patient = @request.auth.id || patient.clinician = @request.auth.id",
    // written through /api/steady/biometrics, which checks consent and validates values
    createRule: null,
    updateRule: null,
    deleteRule: null
  });
  app.save(biometrics);
}, (app) => {
  try { app.delete(app.findCollectionByNameOrId("biometrics")); } catch (_) { /* gone */ }
  const users = app.findCollectionByNameOrId("users");
  for (const f of ["privacyNoticeAt", "privacyNoticeVersion", "wearableConsentAt", "wearableConsentVersion"]) users.fields.removeByName(f);
  users.updateRule = "id = @request.auth.id && @request.body.role:isset = false && @request.body.clinician:isset = false && @request.body.active:isset = false && @request.body.consentAt:isset = false";
  app.save(users);
});
