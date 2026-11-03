/// <reference path="../pb_data/types.d.ts" />
// Steady 1.1 - Android notifications through Firebase Cloud Messaging; UnifiedPush (ntfy) is gone.
//   devices           UnifiedPush registrations are deleted: the relay no longer sends to them.
//                     The updated app registers the phone's Firebase token the next time it
//                     opens; an older copy keeps working without notifications until it's updated.
//   devices.provider  "apns" (iPhones) or "fcm" (Android) only, so no new ones can be added
// SPDX-License-Identifier: AGPL-3.0-or-later

migrate((app) => {
  app.db().newQuery("DELETE FROM devices WHERE provider = 'unifiedpush'").execute();
  const devices = app.findCollectionByNameOrId("devices");
  devices.fields.getByName("provider").values = ["apns", "fcm"];
  app.save(devices);
}, (app) => {
  // the registrations themselves don't come back: phones register again when the app opens
  const devices = app.findCollectionByNameOrId("devices");
  devices.fields.getByName("provider").values = ["apns", "fcm", "unifiedpush"];
  app.save(devices);
});
