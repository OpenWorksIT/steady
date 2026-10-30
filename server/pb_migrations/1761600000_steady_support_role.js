/// <reference path="../pb_data/types.d.ts" />
// Steady 1.0 - five kinds of account: patient, clinician, master clinician (a clinician with
// "master"), practice admin ("admin": the practice's receptionist or administrator) and OpenWorks
// admin ("support"). OpenWorks support used to be an "admin" account marked serverAdmin; it
// becomes "support", which sees psychologists and the system but no patients at all.
// SPDX-License-Identifier: AGPL-3.0-or-later

migrate((app) => {
  const users = app.findCollectionByNameOrId("users");
  const role = users.fields.getByName("role");
  if (role.values.indexOf("support") < 0) role.values = role.values.concat(["support"]);
  app.save(users);
  app.findRecordsByFilter("users", "role = 'admin' && serverAdmin = true", "", 1000, 0).forEach((u) => {
    u.set("role", "support");
    u.set("serverAdmin", false);
    app.save(u);
  });
}, (app) => {
  app.findRecordsByFilter("users", "role = 'support'", "", 1000, 0).forEach((u) => {
    u.set("role", "admin");
    u.set("serverAdmin", true);
    app.save(u);
  });
  const users = app.findCollectionByNameOrId("users");
  const role = users.fields.getByName("role");
  role.values = role.values.filter((v) => v !== "support");
  app.save(users);
});
