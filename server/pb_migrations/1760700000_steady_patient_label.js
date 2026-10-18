/// <reference path="../pb_data/types.d.ts" />
// Steady - the name a psychologist knows a patient by.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The patient's own "name" is what the app calls them. "clinicianLabel" is the name the
// psychologist typed when creating the invite; the psychologist's screens show it. It is
// hidden from the API (patients never see it) and set only through Steady's routes.

const LOCK = " && @request.body.clinicianLabel:isset = false";

migrate((app) => {
  const users = app.findCollectionByNameOrId("users");
  users.fields.add(new TextField({ name: "clinicianLabel", max: 80, hidden: true }));
  if (users.updateRule && users.updateRule.indexOf("clinicianLabel") < 0) users.updateRule = users.updateRule + LOCK;
  app.save(users);

  // patients who joined before this: take the label from the invite they used
  const used = app.findRecordsByFilter("invites", "usedBy != ''", "", 10000, 0);
  used.forEach((inv) => {
    const label = inv.getString("label");
    if (!label) return;
    try {
      const u = app.findRecordById("users", inv.getString("usedBy"));
      if (!u.getString("clinicianLabel")) {
        u.set("clinicianLabel", label);
        app.save(u);
      }
    } catch (_) { /* user gone */ }
  });
}, (app) => {
  const users = app.findCollectionByNameOrId("users");
  users.fields.removeByName("clinicianLabel");
  if (users.updateRule) users.updateRule = users.updateRule.replace(LOCK, "");
  app.save(users);
});
