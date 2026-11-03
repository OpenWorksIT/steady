// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The iOS side lives in ios/Classes/SteadyApnsPlugin.swift and talks over the
// 'za.co.openworks.steady/push' method channel used by lib/services/push.dart:
//   Dart -> iOS  register()          asks permission, registers with APNs, returns bool
//   iOS -> Dart  onToken({token, sandbox})
//   iOS -> Dart  onTap()               a notification was tapped (it carries nothing else)
const steadyPushChannel = 'za.co.openworks.steady/push';
