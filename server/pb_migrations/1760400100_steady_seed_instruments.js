/// <reference path="../pb_data/types.d.ts" />
// Steady - seed the built-in questionnaires and exercises.
// SPDX-License-Identifier: AGPL-3.0-or-later

migrate((app) => {
  const core = require(`${__hooks}/lib/core.js`);
  const { BUILTIN } = require(`${__hooks}/lib/instruments.js`);
  const col = app.findCollectionByNameOrId("instruments");

  for (const raw of BUILTIN) {
    const v = core.validateInstrument(raw);
    if (!v.ok) throw new Error("Built-in instrument " + raw.key + " is invalid: " + v.errors.join("; "));
    let rec;
    try {
      rec = app.findFirstRecordByFilter("instruments", "key = {:key}", { key: v.def.key });
    } catch (_) {
      rec = new Record(col);
    }
    rec.set("key", v.def.key);
    rec.set("name", v.def.name);
    rec.set("kind", v.def.kind);
    rec.set("definition", v.def);
    rec.set("licenceStatus", v.def.licence.status);
    rec.set("builtin", true);
    rec.set("active", true);
    app.save(rec);
  }
}, (app) => {
  const { BUILTIN } = require(`${__hooks}/lib/instruments.js`);
  for (const raw of BUILTIN) {
    try { app.delete(app.findFirstRecordByFilter("instruments", "key = {:key}", { key: raw.key })); } catch (_) { /* not there */ }
  }
});
