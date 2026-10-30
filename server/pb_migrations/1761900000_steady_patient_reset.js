/// <reference path="../pb_data/types.d.ts" />
// Steady 1.0 - a patient's password reset by the practice admin or the master clinician is
// finished only with a code emailed to the patient, so whoever reset it can't choose the new
// password themselves and read the patient's data.
//   users.resetCode        { hash, expires, tries } of the emailed code. Hidden.
//   users.emailCodeNeeded  true while that code is still to be entered (the app shows the field).
// SPDX-License-Identifier: AGPL-3.0-or-later

const RESET_FIELDS = ["resetCode", "emailCodeNeeded"];

migrate((app) => {
  const users = app.findCollectionByNameOrId("users");
  users.fields.add(new JSONField({ name: "resetCode", maxSize: 500, hidden: true }));
  users.fields.add(new BoolField({ name: "emailCodeNeeded" }));
  const rule = users.updateRule === null || users.updateRule === undefined ? null : String(users.updateRule);
  if (rule !== null && rule.indexOf("resetCode") < 0) {
    users.updateRule = rule + RESET_FIELDS.map((f) => " && @request.body." + f + ":isset = false").join("");
  }
  app.save(users);
}, (app) => {
  const users = app.findCollectionByNameOrId("users");
  RESET_FIELDS.forEach((f) => users.fields.removeByName(f));
  const rule = users.updateRule === null || users.updateRule === undefined ? null : String(users.updateRule);
  if (rule !== null) users.updateRule = RESET_FIELDS.reduce((r, f) => r.split(" && @request.body." + f + ":isset = false").join(""), rule);
  app.save(users);
});
