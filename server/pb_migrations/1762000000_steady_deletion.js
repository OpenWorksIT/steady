/// <reference path="../pb_data/types.d.ts" />
// Steady 1.0.2 - a patient can ask, in the app, for their account to be deleted (Apple requires
// it of apps where people create their account). The practice deletes it: it first keeps what
// the law requires in its own clinical records (see lib/deletion.js).
//   users.deletionRequestedAt   when the patient asked. Set only by the server.
// SPDX-License-Identifier: AGPL-3.0-or-later

const DELETION_FIELDS = ["deletionRequestedAt"];

migrate((app) => {
  const users = app.findCollectionByNameOrId("users");
  users.fields.add(new DateField({ name: "deletionRequestedAt" }));
  const rule = users.updateRule === null || users.updateRule === undefined ? null : String(users.updateRule);
  if (rule !== null && rule.indexOf("deletionRequestedAt") < 0) {
    users.updateRule = rule + DELETION_FIELDS.map((f) => " && @request.body." + f + ":isset = false").join("");
  }
  app.save(users);
}, (app) => {
  const users = app.findCollectionByNameOrId("users");
  DELETION_FIELDS.forEach((f) => users.fields.removeByName(f));
  const rule = users.updateRule === null || users.updateRule === undefined ? null : String(users.updateRule);
  if (rule !== null) users.updateRule = DELETION_FIELDS.reduce((r, f) => r.split(" && @request.body." + f + ":isset = false").join(""), rule);
  app.save(users);
});
