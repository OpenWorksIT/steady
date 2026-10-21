/// <reference path="../pb_data/types.d.ts" />
// Steady - practice roles, shared patients, password resets and two-step sign-in.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Roles
//   patient          : as before.
//   clinician        : as before, plus colleagues' patients they were given read access to.
//   clinician+master : also manages the practice's staff accounts (create, reset, stop).
//   admin            : the practice administrator, or OpenWorks support (separate accounts).
//                      Sees names only, never check-ins, scores or watch data. Works only
//                      through /api/steady/admin routes; collection rules give it nothing else.
// Accounts with mustChangePassword (after a reset) can do nothing but choose a new password.

const GUARD = "@request.auth.active = true && @request.auth.mustChangePassword = false";
// added after GUARD on start-up when staff must use two-step sign-in (STEADY_REQUIRE_2FA)
const TWO_STEP = " && (@request.auth.role = 'patient' || @request.auth.totpEnabledAt != '')";
const OLD_GUARD = "@request.auth.active = true";

const RULES = {
  users: {
    listRule: GUARD + " && (id = @request.auth.id || id = @request.auth.clinician || (@request.auth.role = 'clinician' && (clinician = @request.auth.id || sharedWith.id ?= @request.auth.id)))"
  },
  checkins: {
    listRule: GUARD + " && (patient = @request.auth.id || patient.clinician = @request.auth.id || patient.sharedWith.id ?= @request.auth.id)"
  },
  assignments: {
    // follows the patient's current psychologist (patients can be moved to a colleague)
    listRule: GUARD + " && (patient = @request.auth.id || patient.clinician = @request.auth.id || patient.sharedWith.id ?= @request.auth.id)"
  },
  biometrics: {
    listRule: GUARD + " && (patient = @request.auth.id || patient.clinician = @request.auth.id || patient.sharedWith.id ?= @request.auth.id)"
  }
};
const BEFORE = {
  users: { listRule: OLD_GUARD + " && (id = @request.auth.id || id = @request.auth.clinician || (@request.auth.role = 'clinician' && clinician = @request.auth.id))" },
  checkins: { listRule: OLD_GUARD + " && (patient = @request.auth.id || patient.clinician = @request.auth.id)" },
  assignments: { listRule: OLD_GUARD + " && (patient = @request.auth.id || clinician = @request.auth.id)" },
  biometrics: { listRule: OLD_GUARD + " && (patient = @request.auth.id || patient.clinician = @request.auth.id)" }
};

const COLLECTIONS = ["users", "checkins", "assignments", "biometrics", "notifications", "devices", "invites", "instruments"];
const RULE_NAMES = ["listRule", "viewRule", "createRule", "updateRule", "deleteRule"];
const ROLE_LOCK = " && @request.body.master:isset = false && @request.body.mustChangePassword:isset = false" +
  " && @request.body.sharedWith:isset = false && @request.body.totpSecret:isset = false" +
  " && @request.body.totpEnabledAt:isset = false && @request.body.totpLastStep:isset = false && @request.body.recoveryCodes:isset = false";

const NEW_LIMITS = [
  // a patient sending dozens of check-ins would flood their psychologist with notifications
  { label: "checkins:create", audience: "", duration: 600, maxRequests: 10 },
  { label: "POST /api/steady/self-start", audience: "", duration: 600, maxRequests: 10 },
  { label: "POST /api/steady/people/", audience: "", duration: 300, maxRequests: 20 },
  { label: "POST /api/steady/auth/", audience: "", duration: 60, maxRequests: 10 },
  { label: "POST /api/steady/me/", audience: "", duration: 300, maxRequests: 10 },
  { label: "/api/steady/integration/", audience: "", duration: 60, maxRequests: 120 }
];

// Rules come back from the collection as wrapped strings (typeof "object"), or null.
function text(rule) {
  return rule === null || rule === undefined ? null : String(rule);
}

function swapGuard(rule, from, to) {
  const r = text(rule);
  return r === null ? null : r.split(from).join(to);
}

migrate((app) => {
  const users = app.findCollectionByNameOrId("users");
  const role = users.fields.getByName("role");
  role.values = ["patient", "clinician", "admin"];
  users.fields.add(new BoolField({ name: "master" }));
  users.fields.add(new BoolField({ name: "mustChangePassword" }));
  users.fields.add(new RelationField({ name: "sharedWith", collectionId: users.id, maxSelect: 30, cascadeDelete: false }));
  users.fields.add(new TextField({ name: "totpSecret", max: 64, hidden: true }));
  users.fields.add(new DateField({ name: "totpEnabledAt" }));
  users.fields.add(new NumberField({ name: "totpLastStep", onlyInt: true, hidden: true }));
  users.fields.add(new JSONField({ name: "recoveryCodes", maxSize: 4000, hidden: true }));
  app.save(users);

  COLLECTIONS.forEach((name) => {
    const col = app.findCollectionByNameOrId(name);
    RULE_NAMES.forEach((r) => {
      const rule = text(col[r]);
      if (rule !== null && rule.indexOf("mustChangePassword") < 0) col[r] = swapGuard(rule, OLD_GUARD, GUARD);
    });
    const extra = RULES[name];
    if (extra) {
      col.listRule = extra.listRule;
      col.viewRule = extra.listRule;
    }
    if (name === "users" && text(col.updateRule) && text(col.updateRule).indexOf("totpSecret") < 0) col.updateRule = text(col.updateRule) + ROLE_LOCK;
    app.save(col);
  });

  const settings = app.settings();
  const rules = settings.rateLimits.rules || [];
  const have = {};
  rules.forEach((r) => { have[r.label] = true; });
  // more specific labels go before the catch-all "/api/"
  const tail = rules.filter((r) => r.label === "/api/");
  const head = rules.filter((r) => r.label !== "/api/");
  NEW_LIMITS.forEach((r) => { if (!have[r.label]) head.push(r); });
  settings.rateLimits.rules = head.concat(tail);
  app.save(settings);
}, (app) => {
  COLLECTIONS.forEach((name) => {
    const col = app.findCollectionByNameOrId(name);
    RULE_NAMES.forEach((r) => { col[r] = swapGuard(swapGuard(col[r], TWO_STEP, ""), GUARD, OLD_GUARD); });
    if (BEFORE[name]) { col.listRule = BEFORE[name].listRule; col.viewRule = BEFORE[name].listRule; }
    if (name === "users" && text(col.updateRule)) col.updateRule = text(col.updateRule).replace(ROLE_LOCK, "");
    app.save(col);
  });
  const users = app.findCollectionByNameOrId("users");
  ["master", "mustChangePassword", "sharedWith", "totpSecret", "totpEnabledAt", "totpLastStep", "recoveryCodes"].forEach((f) => users.fields.removeByName(f));
  users.fields.getByName("role").values = ["patient", "clinician"];
  app.save(users);
  const settings = app.settings();
  const labels = NEW_LIMITS.map((r) => r.label);
  settings.rateLimits.rules = (settings.rateLimits.rules || []).filter((r) => labels.indexOf(r.label) < 0);
  app.save(settings);
});
