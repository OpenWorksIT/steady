/// <reference path="../pb_data/types.d.ts" />
// Steady - RADR flags marked as reviewed:
//   radrreviews  who marked which run of days away from usual as reviewed, and when, with an
//                optional note. key "radr:<domain>:<since>" (lib/radr.js flags): a review holds
//                until something new appears, then the new flag needs its own.
// API rules: none, so the collections API is closed to every app account. Only the routes in
// steady_research.pb.js read and write it, for staff who may see the patient: their own
// psychologist, or a colleague the patient is shared with (lib/server.js viewablePatient).
// Patients, the practice admin and OpenWorks support never reach it. Reads are access-logged.
// Goes with the patient's account when it is deleted (lib/deletion.js).
// SPDX-License-Identifier: AGPL-3.0-or-later

migrate((app) => {
  const users = app.findCollectionByNameOrId("users");
  app.save(new Collection({
    type: "base",
    name: "radrreviews",
    fields: [
      { name: "patient", type: "relation", collectionId: users.id, maxSelect: 1, required: true, cascadeDelete: true },
      { name: "key", type: "text", max: 80, required: true },
      { name: "domain", type: "text", max: 20 },
      { name: "since", type: "text", max: 10 },
      { name: "day", type: "text", max: 10 },
      { name: "score", type: "number" },
      { name: "reviewer", type: "relation", collectionId: users.id, maxSelect: 1, cascadeDelete: false },
      { name: "reviewerName", type: "text", max: 120 },
      { name: "note", type: "text", max: 500 },
      { name: "created", type: "autodate", onCreate: true, onUpdate: false },
      { name: "updated", type: "autodate", onCreate: true, onUpdate: true }
    ],
    indexes: ["CREATE UNIQUE INDEX `idx_radrreviews_key` ON `radrreviews` (`patient`, `key`)"],
    listRule: null, viewRule: null, createRule: null, updateRule: null, deleteRule: null
  }));
}, (app) => {
  try { app.delete(app.findCollectionByNameOrId("radrreviews")); } catch (_) { /* gone */ }
});
