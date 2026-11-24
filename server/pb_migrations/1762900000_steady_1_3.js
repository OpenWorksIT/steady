/// <reference path="../pb_data/types.d.ts" />
// Steady 1.3.0:
//   users.radrBaseline      the patient's RADR baseline started again: { from, by, at, reason }
//                           (lib/radr_data.js). Hidden: a clinician's setting, like radrExclusions.
//   users.contactConsent    the patient's answer to "my practice may contact me about what I share
//                           in Steady": "yes", "no", or empty (not asked yet). Their own to read.
//   users.contactConsentAt  when they answered.
// All set through /api/steady routes only (join, consent, radr-baseline), never the REST API.
// SPDX-License-Identifier: AGPL-3.0-or-later

const FIELDS = ["radrBaseline", "contactConsent", "contactConsentAt"];

migrate((app) => {
  const users = app.findCollectionByNameOrId("users");
  users.fields.add(new JSONField({ name: "radrBaseline", maxSize: 1000, hidden: true }));
  users.fields.add(new SelectField({ name: "contactConsent", maxSelect: 1, values: ["yes", "no"] }));
  users.fields.add(new DateField({ name: "contactConsentAt" }));
  let rule = users.updateRule === null || users.updateRule === undefined ? null : String(users.updateRule);
  if (rule !== null) {
    FIELDS.forEach((f) => {
      if (rule.indexOf("@request.body." + f + ":isset") < 0) rule += " && @request.body." + f + ":isset = false";
    });
    users.updateRule = rule;
  }
  app.save(users);
}, (app) => {
  const users = app.findCollectionByNameOrId("users");
  FIELDS.forEach((f) => users.fields.removeByName(f));
  let rule = users.updateRule === null || users.updateRule === undefined ? null : String(users.updateRule);
  if (rule !== null) {
    FIELDS.forEach((f) => { rule = rule.split(" && @request.body." + f + ":isset = false").join(""); });
    users.updateRule = rule;
  }
  app.save(users);
});
