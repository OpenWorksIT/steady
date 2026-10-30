/// <reference path="../pb_data/types.d.ts" />
// Steady 1.0 - what a patient's app may see of records the API rules let it read. Applies to
// lists, single records, expand= and realtime alike (PocketBase "enriches" every record it
// sends through here).
//   - Questionnaire scores, bands and flags go to the psychologist, never to the patient (a
//     patient reading "item 9 endorsed" or "severe" alone, between sessions, isn't care).
//   - Of their psychologist's account, a patient sees the id and name only.
// SPDX-License-Identifier: AGPL-3.0-or-later

onRecordEnrich((e) => {
  const info = e.requestInfo;
  const auth = info ? info.auth : null;
  if (auth && !auth.isSuperuser() && auth.getString("role") === "patient") e.record.hide("score");
  e.next();
}, "assignments");

onRecordEnrich((e) => {
  const info = e.requestInfo;
  const auth = info ? info.auth : null;
  if (auth && !auth.isSuperuser() && auth.getString("role") === "patient" && e.record.id !== auth.id) {
    e.record.hide("email", "emailVisibility", "verified", "role", "clinician", "active", "master", "serverAdmin", "mustChangePassword",
      "sharedWith", "totpEnabledAt", "demo", "appBuild", "appPlatform", "appSeenAt", "healthPerm", "consentAt", "consentVersion",
      "privacyNoticeAt", "privacyNoticeVersion", "wearableConsentAt", "wearableConsentVersion", "tzOffset", "created", "updated", "avatar");
  }
  e.next();
}, "users");
