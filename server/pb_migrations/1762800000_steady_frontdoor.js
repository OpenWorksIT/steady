/// <reference path="../pb_data/types.d.ts" />
// Steady 1.2.7 - the front door (lib/frontdoor.js): what the server turned away, one row an
// hour, kept 30 days, and tripwire touches with them. Read only through /api/steady/fleet.
// SPDX-License-Identifier: AGPL-3.0-or-later

migrate((app) => {
  const frontdoor = new Collection({
    type: "base",
    name: "frontdoor",
    fields: [
      { name: "hour", type: "text", required: true, max: 20 },
      { name: "data", type: "json", maxSize: 60000 },
      { name: "created", type: "autodate", onCreate: true, onUpdate: false }
    ],
    indexes: ["CREATE UNIQUE INDEX `idx_frontdoor_hour` ON `frontdoor` (`hour`)"],
    listRule: null, viewRule: null, createRule: null, updateRule: null, deleteRule: null
  });
  app.save(frontdoor);
}, (app) => {
  try { app.delete(app.findCollectionByNameOrId("frontdoor")); } catch (_) { /* gone */ }
});
