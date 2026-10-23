/// <reference path="../pb_data/types.d.ts" />
// Steady - an index for a psychologist's patient list (psychiatrists may have thousands), and
// the minute-by-minute health log behind Settings > Server health (lib/health.js).
// SPDX-License-Identifier: AGPL-3.0-or-later

migrate((app) => {
  const users = app.findCollectionByNameOrId("users");
  users.addIndex("idx_users_clinician_role", false, "clinician, role", "");
  app.save(users);

  const healthlog = new Collection({
    type: "base",
    name: "healthlog",
    fields: [
      { name: "minute", type: "text", required: true, max: 20 },
      { name: "data", type: "json", maxSize: 20000 },
      { name: "created", type: "autodate", onCreate: true, onUpdate: false }
    ],
    indexes: ["CREATE UNIQUE INDEX `idx_healthlog_minute` ON `healthlog` (`minute`)"],
    // read only through /api/steady/health
    listRule: null, viewRule: null, createRule: null, updateRule: null, deleteRule: null
  });
  app.save(healthlog);
}, (app) => {
  try { app.delete(app.findCollectionByNameOrId("healthlog")); } catch (_) { /* gone */ }
  const users = app.findCollectionByNameOrId("users");
  users.removeIndex("idx_users_clinician_role");
  app.save(users);
});
