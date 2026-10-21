/// <reference path="../pb_data/types.d.ts" />
// Steady - psychologists who may check for and install server updates from the app.
// Ticked by the superuser in the dashboard; nobody can set it on themselves.
// SPDX-License-Identifier: AGPL-3.0-or-later

const SERVER_ADMIN_LOCK = " && @request.body.serverAdmin:isset = false";

migrate((app) => {
  const users = app.findCollectionByNameOrId("users");
  users.fields.add(new BoolField({ name: "serverAdmin" }));
  if (users.updateRule && users.updateRule.indexOf("serverAdmin") < 0) users.updateRule = users.updateRule + SERVER_ADMIN_LOCK;
  app.save(users);
}, (app) => {
  const users = app.findCollectionByNameOrId("users");
  users.fields.removeByName("serverAdmin");
  if (users.updateRule) users.updateRule = users.updateRule.replace(SERVER_ADMIN_LOCK, "");
  app.save(users);
});
