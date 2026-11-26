/// <reference path="../pb_data/types.d.ts" />
// Steady - for Kempie van Rooyen's substance use measurement paper:
//   - the measures free to build in (AUDIT, AWARE, drug use and heavy drinking in the past 7
//     days), added to servers seeded before them. Only where missing: a practice's own changes
//     to a built-in (archived, a licence confirmed) stay as they are;
//   - the cadences it recommends: assignments repeat fortnightly, monthly or quarterly too.
// SPDX-License-Identifier: AGPL-3.0-or-later

migrate((app) => {
  const core = require(`${__hooks}/lib/core.js`);
  const { BUILTIN, SUBSTANCE_KEYS } = require(`${__hooks}/lib/instruments.js`);
  const asg = app.findCollectionByNameOrId("assignments");
  asg.fields.getByName("repeat").values = core.REPEATS;
  app.save(asg);
  const col = app.findCollectionByNameOrId("instruments");
  for (const raw of BUILTIN) {
    if (SUBSTANCE_KEYS.indexOf(raw.key) < 0) continue;
    try {
      app.findFirstRecordByFilter("instruments", "key = {:key}", { key: raw.key });
      continue; // already there
    } catch (_) { /* add it */ }
    const v = core.validateInstrument(raw);
    if (!v.ok) throw new Error("Built-in instrument " + raw.key + " is invalid: " + v.errors.join("; "));
    const rec = new Record(col);
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
  const asg = app.findCollectionByNameOrId("assignments");
  asg.fields.getByName("repeat").values = ["once", "daily", "weekly"];
  app.save(asg);
  const { SUBSTANCE_KEYS } = require(`${__hooks}/lib/instruments.js`);
  for (const key of SUBSTANCE_KEYS) {
    try {
      const rec = app.findFirstRecordByFilter("instruments", "key = {:key}", { key: key });
      // only if it was never sent to anyone
      if (app.findRecordsByFilter("assignments", "instrument = {:id}", "", 1, 0, { id: rec.id }).length === 0) app.delete(rec);
    } catch (_) { /* not there */ }
  }
});
