/// <reference path="../pb_data/types.d.ts" />
// Steady - security hardening (October 2026 review).
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  - Stopped accounts lose access through the collection API too, not only the Steady routes.
//  - Consent records and notification contents can't be edited by their owners.
//  - Passwords need at least 10 characters (the join route already asks for 10).
//  - Rate limits on, with the client's real address taken from the reverse proxy.

const ACTIVE = "@request.auth.active = true";

function guard(rule) {
  return rule === null || rule === undefined ? rule : ACTIVE + " && (" + rule + ")";
}

function unguard(rule) {
  const prefix = ACTIVE + " && (";
  const r = rule === null || rule === undefined ? null : String(rule);
  return r !== null && r.indexOf(prefix) === 0 ? r.slice(prefix.length, -1) : rule;
}

const GUARDED = {
  users: ["listRule", "viewRule"],
  checkins: ["listRule", "viewRule", "createRule"],
  assignments: ["listRule", "viewRule", "createRule"],
  biometrics: ["listRule", "viewRule"],
  notifications: ["listRule", "viewRule", "updateRule", "deleteRule"],
  devices: ["listRule", "viewRule", "createRule", "updateRule", "deleteRule"],
  invites: ["listRule", "viewRule", "deleteRule"],
  instruments: ["listRule", "viewRule"]
};

const USERS_UPDATE = "id = @request.auth.id && @request.auth.active = true" +
  " && @request.body.role:isset = false && @request.body.clinician:isset = false && @request.body.active:isset = false" +
  " && @request.body.consentAt:isset = false && @request.body.consentVersion:isset = false" +
  " && @request.body.privacyNoticeAt:isset = false && @request.body.privacyNoticeVersion:isset = false" +
  " && @request.body.wearableConsentAt:isset = false && @request.body.wearableConsentVersion:isset = false";

const USERS_UPDATE_BEFORE = "id = @request.auth.id && @request.body.role:isset = false && @request.body.clinician:isset = false && @request.body.active:isset = false && @request.body.consentAt:isset = false" +
  " && @request.body.privacyNoticeAt:isset = false && @request.body.privacyNoticeVersion:isset = false" +
  " && @request.body.wearableConsentAt:isset = false && @request.body.wearableConsentVersion:isset = false";

// Only "read" may change on your own notifications.
const NOTIFICATIONS_UPDATE = "recipient = @request.auth.id && @request.body.recipient:isset = false" +
  " && @request.body.title:isset = false && @request.body.body:isset = false && @request.body.kind:isset = false" +
  " && @request.body.patient:isset = false && @request.body.assignment:isset = false && @request.body.severity:isset = false";

const NOTIFICATIONS_UPDATE_BEFORE = "recipient = @request.auth.id && @request.body.recipient:isset = false && @request.body.title:isset = false && @request.body.body:isset = false";

migrate((app) => {
  const notifications = app.findCollectionByNameOrId("notifications");
  notifications.updateRule = NOTIFICATIONS_UPDATE;
  app.save(notifications);

  Object.keys(GUARDED).forEach((name) => {
    const col = app.findCollectionByNameOrId(name);
    GUARDED[name].forEach((rule) => { col[rule] = guard(col[rule]); });
    if (name === "users") {
      col.updateRule = USERS_UPDATE;
      const pw = col.fields.getByName("password");
      if (pw) pw.min = 10;
    }
    app.save(col);
  });

  const settings = app.settings();
  // Caddy (production) sets X-Forwarded-For to the address it saw; the test stack's
  // Cloudflare tunnel passes the visitor's address in Cf-Connecting-Ip.
  const header = $os.getenv("STEADY_TRUSTED_PROXY_HEADER") || "X-Forwarded-For";
  settings.trustedProxy.headers = [header];
  settings.trustedProxy.useLeftmostIP = false;
  settings.rateLimits.enabled = true;
  settings.rateLimits.rules = [
    // sign-in, per address: generous for a shared mobile network, slow for guessing
    { label: "*:auth", audience: "", duration: 60, maxRequests: 10 },
    { label: "*:requestPasswordReset", audience: "", duration: 300, maxRequests: 3 },
    { label: "*:confirmPasswordReset", audience: "", duration: 300, maxRequests: 5 },
    { label: "*:requestOTP", audience: "", duration: 300, maxRequests: 5 },
    { label: "*:requestVerification", audience: "", duration: 300, maxRequests: 3 },
    { label: "*:requestEmailChange", audience: "", duration: 300, maxRequests: 3 },
    { label: "POST /api/steady/join", audience: "", duration: 300, maxRequests: 5 },
    { label: "POST /api/steady/invites", audience: "", duration: 60, maxRequests: 20 },
    { label: "POST /api/steady/biometrics", audience: "", duration: 60, maxRequests: 30 },
    { label: "*:create", audience: "", duration: 60, maxRequests: 30 },
    { label: "/api/batch", audience: "", duration: 1, maxRequests: 3 },
    { label: "/api/", audience: "", duration: 10, maxRequests: 300 }
  ];
  app.save(settings);
}, (app) => {
  Object.keys(GUARDED).forEach((name) => {
    const col = app.findCollectionByNameOrId(name);
    GUARDED[name].forEach((rule) => { col[rule] = unguard(col[rule]); });
    if (name === "users") col.updateRule = USERS_UPDATE_BEFORE;
    if (name === "notifications") col.updateRule = NOTIFICATIONS_UPDATE_BEFORE;
    app.save(col);
  });
  const settings = app.settings();
  settings.rateLimits.enabled = false;
  app.save(settings);
});
