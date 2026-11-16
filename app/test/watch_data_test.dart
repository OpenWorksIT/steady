// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Google Play's Health Connect review (1.2.4): the patient who shares watch data can see it
// themselves, and Health Connect's "why does Steady need this" opens a page that says, for each
// data type, what it is for, where it shows and how it helps.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:steady/content/privacy_notice.dart';
import 'package:steady/services/api.dart';
import 'package:steady/ui/health_data_use.dart';
import 'package:steady/ui/theme.dart';

final _stored = <String, String>{};

String _token() {
  String part(Map<String, Object> m) => base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${part({'alg': 'HS256', 'typ': 'JWT'})}.${part({'id': 'u1', 'type': 'auth', 'exp': 4102444800})}.sig';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    _stored.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), (call) async {
      final args = (call.arguments as Map?) ?? const {};
      final key = '${args['key']}';
      switch (call.method) {
        case 'read':
          return _stored[key];
        case 'write':
          _stored[key] = '${args['value']}';
          return null;
        case 'delete':
          _stored.remove(key);
          return null;
        case 'containsKey':
          return _stored.containsKey(key);
        case 'readAll':
          return Map<String, String>.from(_stored);
      }
      return null;
    });
  });

  test('a patient\'s own watch data comes from their own route, not a psychologist\'s', () async {
    _stored['steady.server'] = 'https://steady.test';
    final asked = <Uri>[];
    final client = MockClient((req) async {
      asked.add(req.url);
      return http.Response(
          jsonEncode({
            'from': '2026-11-10',
            'to': '2026-11-16',
            'connected': true,
            'days': [
              {'day': '2026-11-16', 'values': {'steps': 4200, 'rhr': 58, 'sleep_min': 420, 'spo2_avg': 96}},
            ],
            'baseline': {
              'steps': [
                {'day': '2026-11-16', 'lo': 3000, 'mid': 5000, 'hi': 7000, 'n': 20},
              ],
            },
            'baselineWindow': 28,
            'baselineMin': 7,
          }),
          200,
          headers: {'content-type': 'application/json'});
    });
    final api = await Api.create(httpClient: () => client);
    api.pb.authStore.save(_token(), RecordModel.fromJson({'id': 'u1', 'collectionId': '_pb_users_auth_', 'collectionName': 'users', 'role': 'patient'}));
    final mine = await api.myBiometrics(from: '2026-11-10', to: '2026-11-16');
    expect(asked.single.path, '/api/steady/me/biometrics');
    expect(asked.single.queryParameters, {'from': '2026-11-10', 'to': '2026-11-16'});
    expect(mine.connected, isTrue);
    expect(mine.days.single.number('steps'), 4200);
    expect(mine.days.single.number('spo2_avg'), 96);
    expect(mine.baseline['steps']!.single.mid, 5000);
  });

  testWidgets('the page says what each kind of watch data is for, where it shows, and the privacy notice', (tester) async {
    // a screen tall enough for the whole page, so the list builds all of it
    tester.view.physicalSize = const Size(800, 8000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: const HealthDataUseScreen()));
    expect(healthDataUses.map((u) => u.$1), ['Heart rate', 'Sleep', 'Steps', 'Blood oxygen']);
    expect(find.textContaining('optional, and you can stop'), findsOneWidget);
    for (final (title, body) in healthDataUses) {
      expect(find.text(title), findsOneWidget);
      expect(body, contains('psychologist'), reason: '$title: who it helps');
      expect(body, contains('You'), reason: '$title: the patient sees it too');
    }
    expect(find.text(privacyNoticeTitle), findsOneWidget);
  });

  testWidgets('Health Connect asking why opens the page over whatever is showing (Android)', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      var asks = 0;
      const channel = MethodChannel('steady/healthdata');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'opened') {
          asks++;
          return true;
        }
        return null;
      });
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), navigatorKey: nav, home: const Text('Sign in')));
      HealthDataUse.listen(nav);
      await tester.pumpAndSettle();
      expect(asks, 1);
      expect(find.byType(HealthDataUseScreen), findsOneWidget);
      // back goes to the app as it was
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('Sign in'), findsOneWidget);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
