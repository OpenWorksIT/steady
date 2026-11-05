/// <reference path="../pb_data/types.d.ts" />
// Steady 1.0.5 - the operator agreement between the practice and OpenWorks IT (POPIA section 21),
// signed in the app by the master clinician (lib/operator.js, docs/OPERATOR-AGREEMENT.md).
//   operator_agreements   one row per signature: the version, the exact text and its SHA-256,
//                         the practice's details as given, who signed (copied, not a relation, so
//                         the record outlives the account), when, from which address and app.
// Written only by POST /api/steady/operator-agreement/sign. No API rules, and steady_operator.pb.js
// refuses creating, changing or deleting rows through the API (superusers too) and changing or
// deleting them anywhere in the server: signing again adds a row.
// SPDX-License-Identifier: AGPL-3.0-or-later

migrate((app) => {
  const col = new Collection({
    type: "base",
    name: "operator_agreements",
    fields: [
      { name: "version", type: "text", required: true, max: 40 },
      { name: "sha256", type: "text", required: true, max: 64 },
      { name: "text", type: "text", required: true, max: 100000 },
      { name: "fields", type: "json", maxSize: 20000 },
      { name: "signerId", type: "text", max: 15 },
      { name: "signerName", type: "text", max: 120 },
      { name: "signerEmail", type: "text", max: 200 },
      { name: "signature", type: "text", max: 120 },
      { name: "signedAt", type: "date", required: true },
      { name: "ip", type: "text", max: 80 },
      { name: "userAgent", type: "text", max: 400 },
      { name: "created", type: "autodate", onCreate: true, onUpdate: false }
    ],
    indexes: ["CREATE INDEX `idx_operator_agreements_signed` ON `operator_agreements` (`version`, `signedAt`)"],
    listRule: null, viewRule: null, createRule: null, updateRule: null, deleteRule: null
  });
  app.save(col);
}, (app) => {
  try { app.delete(app.findCollectionByNameOrId("operator_agreements")); } catch (_) { /* gone */ }
});
