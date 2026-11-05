/// <reference path="../pb_data/types.d.ts" />
// Steady 1.1.1 - anyone can change their own email address in Settings (lib/emailchange.js):
// with their password, and a code sent to the new address.
//   users.emailChange   { email, hash, expires, tries } of the code sent to the new address. Hidden.
// SPDX-License-Identifier: AGPL-3.0-or-later

migrate((app) => {
  const users = app.findCollectionByNameOrId("users");
  users.fields.add(new JSONField({ name: "emailChange", maxSize: 600, hidden: true }));
  const rule = users.updateRule === null || users.updateRule === undefined ? null : String(users.updateRule);
  if (rule !== null && rule.indexOf("emailChange") < 0) {
    users.updateRule = rule + " && @request.body.emailChange:isset = false";
  }
  app.save(users);
}, (app) => {
  const users = app.findCollectionByNameOrId("users");
  users.fields.removeByName("emailChange");
  const rule = users.updateRule === null || users.updateRule === undefined ? null : String(users.updateRule);
  if (rule !== null) users.updateRule = rule.split(" && @request.body.emailChange:isset = false").join("");
  app.save(users);
});
