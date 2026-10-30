/// <reference path="../pb_data/types.d.ts" />
// Steady 1.0 - staff sign in only from devices they've linked:
//   staffdevices  a staff member's linked phones and browsers. The device keeps a random key;
//                 the server keeps only its hash. Signing in needs the password, the
//                 authenticator code and a linked device.
//   devicelinks   a pending link: after the password and code, an emailed 6-digit code links
//                 the new device. Expires after 15 minutes or 5 wrong tries.
//   users.confirmedAt  when the person last confirmed it's them ("confirm it's you", before a
//                 reset, an export, the audit report...). Valid for a few minutes. Hidden.
//   users.authFails    wrong passwords and codes lately: { n, first, until } (a short rest after
//                 too many). Hidden.
//   staffdevices.confirmedAt  "confirm it's you" from that device (it counts for that device only)
// All written through /api/steady routes only; the collections have no API rules.
// SPDX-License-Identifier: AGPL-3.0-or-later

const DEVICE_FIELDS = ["confirmedAt", "authFails"];
// staff can't rename themselves (the audit report and emails go by name); patients can
const NAME_LOCK = " && (@request.auth.role = 'patient' || @request.body.name:isset = false)";

migrate((app) => {
  const users = app.findCollectionByNameOrId("users");
  users.fields.add(new DateField({ name: "confirmedAt", hidden: true }));
  users.fields.add(new JSONField({ name: "authFails", maxSize: 500, hidden: true }));
  const rule = users.updateRule === null || users.updateRule === undefined ? null : String(users.updateRule);
  if (rule !== null && rule.indexOf("confirmedAt") < 0) {
    users.updateRule = rule + DEVICE_FIELDS.map((f) => " && @request.body." + f + ":isset = false").join("") + NAME_LOCK;
  }
  app.save(users);

  app.save(new Collection({
    type: "base",
    name: "staffdevices",
    fields: [
      { name: "user", type: "relation", collectionId: users.id, maxSelect: 1, required: true, cascadeDelete: true },
      { name: "name", type: "text", max: 80 },
      { name: "platform", type: "text", max: 20 },
      { name: "keyHash", type: "text", max: 100, required: true, hidden: true },
      { name: "lastUsedAt", type: "date" },
      { name: "lastIp", type: "text", max: 80 },
      { name: "confirmedAt", type: "date", hidden: true },
      { name: "created", type: "autodate", onCreate: true, onUpdate: false }
    ],
    indexes: ["CREATE UNIQUE INDEX `idx_staffdevices_key` ON `staffdevices` (`user`, `keyHash`)"],
    listRule: null, viewRule: null, createRule: null, updateRule: null, deleteRule: null
  }));

  app.save(new Collection({
    type: "base",
    name: "devicelinks",
    fields: [
      { name: "user", type: "relation", collectionId: users.id, maxSelect: 1, required: true, cascadeDelete: true },
      { name: "ticketHash", type: "text", max: 100, required: true, hidden: true },
      { name: "codeHash", type: "text", max: 100, required: true, hidden: true },
      { name: "keyHash", type: "text", max: 100, required: true, hidden: true },
      { name: "name", type: "text", max: 80 },
      { name: "platform", type: "text", max: 20 },
      { name: "ip", type: "text", max: 80 },
      { name: "attempts", type: "number", onlyInt: true },
      { name: "expiresAt", type: "date", required: true },
      { name: "created", type: "autodate", onCreate: true, onUpdate: false }
    ],
    indexes: ["CREATE UNIQUE INDEX `idx_devicelinks_ticket` ON `devicelinks` (`ticketHash`)", "CREATE INDEX `idx_devicelinks_user` ON `devicelinks` (`user`, `created`)"],
    listRule: null, viewRule: null, createRule: null, updateRule: null, deleteRule: null
  }));
}, (app) => {
  ["staffdevices", "devicelinks"].forEach((n) => { try { app.delete(app.findCollectionByNameOrId(n)); } catch (_) { /* gone */ } });
  const users = app.findCollectionByNameOrId("users");
  DEVICE_FIELDS.forEach((f) => users.fields.removeByName(f));
  const rule = users.updateRule === null || users.updateRule === undefined ? null : String(users.updateRule);
  if (rule !== null) users.updateRule = DEVICE_FIELDS.reduce((r, f) => r.split(" && @request.body." + f + ":isset = false").join(""), rule).split(NAME_LOCK).join("");
  app.save(users);
});
