// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Android side lives in android/src/main/java/za/co/openworks/steady/fcm/ and talks over the
// 'za.co.openworks.steady/fcm' method channel used by lib/services/push.dart:
//   Dart -> Android  register({apiKey, appId, senderId, projectId})  asks permission, returns the
//                    Firebase token, or null when the phone doesn't allow notifications
//   Dart -> Android  unregister({the same})                          deletes the token
//   Android -> Dart  onTap()                                         a notification was tapped
// There is no google-services.json: the app passes in the Firebase settings it was built with.
const steadyFcmChannel = 'za.co.openworks.steady/fcm';
