/// <reference path="../pb_data/types.d.ts" />
// Steady - feedback from the psychologists' and administrators' screens ("Love this",
// "Don't like this", "Bug found"), with a screenshot (blurred unless they chose otherwise) and
// the last 60 steps for bug reports. Written and read only through /api/steady/feedback.
// SPDX-License-Identifier: AGPL-3.0-or-later

migrate((app) => {
  const users = app.findCollectionByNameOrId("users");
  const feedback = new Collection({
    type: "base",
    name: "feedback",
    fields: [
      { name: "kind", type: "select", required: true, maxSelect: 1, values: ["love", "dislike", "bug"] },
      { name: "message", type: "text", max: 2000 },
      { name: "screen", type: "text", max: 200 },
      { name: "pressedAt", type: "date" },
      { name: "who", type: "relation", collectionId: users.id, maxSelect: 1, cascadeDelete: false },
      { name: "whoName", type: "text", max: 120 },
      { name: "whoRole", type: "text", max: 40 },
      { name: "client", type: "json", maxSize: 4000 },
      { name: "trail", type: "json", maxSize: 60000 },
      { name: "screenshot", type: "file", maxSelect: 1, maxSize: 6291456, mimeTypes: ["image/png", "image/jpeg"], protected: true },
      { name: "screenshotMasked", type: "bool" },
      { name: "status", type: "select", maxSelect: 1, values: ["new", "seen", "done"] },
      { name: "note", type: "text", max: 1000 },
      { name: "statusBy", type: "text", max: 120 },
      { name: "statusAt", type: "date" },
      { name: "created", type: "autodate", onCreate: true, onUpdate: false }
    ],
    indexes: ["CREATE INDEX `idx_feedback_created` ON `feedback` (`created`)"],
    listRule: null, viewRule: null, createRule: null, updateRule: null, deleteRule: null
  });
  app.save(feedback);
}, (app) => {
  try { app.delete(app.findCollectionByNameOrId("feedback")); } catch (_) { /* gone */ }
});
