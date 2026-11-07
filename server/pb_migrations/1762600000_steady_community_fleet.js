/// <reference path="../pb_data/types.d.ts" />
// Steady 1.2 - the community run from OpenWorks' fleet view (lib/community.js):
//   settings            key/value the fleet view sets for this server; only the server reads it
//                       (no API rules). "community": { on, forum, signin, key, openworks }
//   users.community     a staff member the master psychologist has put in the community. Set
//                       only through /api/steady/practice/community. Everyone on staff today
//                       starts in it, so nothing changes for a community already open.
// SPDX-License-Identifier: AGPL-3.0-or-later

migrate((app) => {
  const settings = new Collection({
    type: "base",
    name: "settings",
    listRule: null, viewRule: null, createRule: null, updateRule: null, deleteRule: null,
    fields: [
      { name: "key", type: "text", required: true, max: 60 },
      { name: "value", type: "json", maxSize: 20000 }
    ],
    indexes: ["CREATE UNIQUE INDEX idx_settings_key ON settings (key)"]
  });
  app.save(settings);

  const users = app.findCollectionByNameOrId("users");
  users.fields.add(new BoolField({ name: "community" }));
  const rule = users.updateRule === null || users.updateRule === undefined ? null : String(users.updateRule);
  if (rule !== null && rule.indexOf("community:isset") < 0) {
    users.updateRule = rule + " && @request.body.community:isset = false";
  }
  app.save(users);
  app.findRecordsByFilter("users", "role != 'patient' && role != 'support' && active = true", "", 100000, 0).forEach((u) => {
    u.set("community", true);
    app.unsafeWithoutHooks().save(u);
  });
}, (app) => {
  try { app.delete(app.findCollectionByNameOrId("settings")); } catch (_) { /* gone already */ }
  const users = app.findCollectionByNameOrId("users");
  users.fields.removeByName("community");
  const rule = users.updateRule === null || users.updateRule === undefined ? null : String(users.updateRule);
  if (rule !== null) users.updateRule = rule.split(" && @request.body.community:isset = false").join("");
  app.save(users);
});
