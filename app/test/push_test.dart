// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:steady/services/push.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Settings says what a notification shows, and through whom', () {
    final android = pushStatusText(on: true, web: false, android: true, builtIn: true);
    final iphone = pushStatusText(on: true, web: false, android: false);
    expect(android, contains('"New notification"'));
    expect(android, contains('Google'));
    expect(iphone, contains('"New notification"'));
    expect(iphone, contains('Apple'));
    expect(iphone, isNot(contains('Google')));
    expect(pushStatusText(on: false, web: false, android: true, builtIn: true), contains("phone's settings"));
    expect(pushStatusText(on: false, web: true), contains("web version can't"));
    // forks and local builds: no Firebase settings, so no Android notifications
    expect(pushStatusText(on: false, web: false, android: true, builtIn: false), contains('built without notifications'));
    for (final t in [android, iphone]) {
      expect(t, isNot(contains('!')));
      expect(t.toLowerCase(), isNot(contains('ntfy')));
    }
  });

  test('a build without Firebase settings never asks the phone for a token', () async {
    expect(kAndroidPushBuiltIn, isFalse, reason: 'tests run without --dart-define=FIREBASE_*');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('za.co.openworks.steady/fcm'),
      (call) async {
        calls.add(call.method);
        return 'token';
      },
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      expect(await PushService.instance.enable(), isFalse);
      await PushService.instance.disable();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    expect(calls, isEmpty);
  });
}
