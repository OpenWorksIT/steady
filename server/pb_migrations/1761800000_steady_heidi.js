/// <reference path="../pb_data/types.d.ts" />
// Steady 1.0 - Heidi-ready exports can continue where the last one stopped:
//   users.lastHeidiExport  { at, from, to, part, by, radr } of the patient's last Heidi export
//                          (part counts the files in the series). Hidden: only the routes read it.
// SPDX-License-Identifier: AGPL-3.0-or-later

const HEIDI_FIELDS = ["lastHeidiExport"];

migrate((app) => {
  const users = app.findCollectionByNameOrId("users");
  users.fields.add(new JSONField({ name: "lastHeidiExport", maxSize: 2000, hidden: true }));
  const rule = users.updateRule === null || users.updateRule === undefined ? null : String(users.updateRule);
  if (rule !== null && rule.indexOf("lastHeidiExport") < 0) {
    users.updateRule = rule + HEIDI_FIELDS.map((f) => " && @request.body." + f + ":isset = false").join("");
  }
  app.save(users);
}, (app) => {
  const users = app.findCollectionByNameOrId("users");
  HEIDI_FIELDS.forEach((f) => users.fields.removeByName(f));
  const rule = users.updateRule === null || users.updateRule === undefined ? null : String(users.updateRule);
  if (rule !== null) users.updateRule = HEIDI_FIELDS.reduce((r, f) => r.split(" && @request.body." + f + ":isset = false").join(""), rule);
  app.save(users);
});
