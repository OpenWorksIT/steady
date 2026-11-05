// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:steady/app_state.dart';
import 'package:steady/services/api.dart';
import 'package:steady/ui/auth/screen_lock.dart';
import 'package:steady/ui/theme.dart';

/// The phone's screen lock, answering as told.
class _FakeAuth extends ScreenLockAuth {
  _FakeAuth({this.hasLock = true, List<bool>? answers}) : answers = answers ?? [];
  bool hasLock;
  final List<bool> answers;
  int asked = 0;
  @override
  Future<bool> available() async => hasLock;
  @override
  Future<bool> unlock(String reason) async {
    asked++;
    return answers.isEmpty ? false : answers.removeAt(0);
  }
}

// secure storage, in memory (the session, and the patient's Lock Steady setting)
final _stored = <String, String>{};

String _token({int exp = 4102444800}) {
  String part(Map<String, Object> m) => base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${part({'alg': 'HS256', 'typ': 'JWT'})}.${part({'id': 'u1', 'type': 'auth', 'exp': exp})}.sig';
}

void _signIn(AppState state, String role, {int exp = 4102444800}) {
  state.api.pb.authStore.save(
      _token(exp: exp),
      RecordModel.fromJson(
          {'id': 'u1', 'collectionId': '_pb_users_auth_', 'collectionName': 'users', 'role': role, 'name': 'Sam', 'email': 'sam@example.org'}));
  state.changed();
}

Future<AppState> _state({String? role}) async {
  final state = AppState(await Api.create());
  if (role != null) _signIn(state, role);
  return state;
}

Widget _app(AppState state, ScreenLockAuth auth, PatientLock lock, {DateTime Function()? now}) => AppScope(
      state: state,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        builder: (context, child) => ScreenLock(auth: auth, patientLock: lock, now: now ?? DateTime.now, child: child!),
        home: const Scaffold(body: Text('home')),
      ),
    );

Future<void> _lifecycle(WidgetTester tester, AppLifecycleState s) async {
  await tester.binding.defaultBinaryMessenger
      .handlePlatformMessage(SystemChannels.lifecycle.name, const StringCodec().encodeMessage(s.toString()), (_) {});
  await tester.pumpAndSettle();
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

  testWidgets('Lock Steady is off unless the patient turns it on: nothing is locked or asked', (tester) async {
    final auth = _FakeAuth();
    await tester.pumpWidget(_app(await _state(role: 'patient'), auth, PatientLock()));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect(find.text('Steady is locked'), findsNothing);
    expect(auth.asked, 0);
  });

  testWidgets('with Lock Steady on, opening the app asks for the screen lock; the crisis numbers stay and it can be tried again',
      (tester) async {
    _stored['steady.patientlock.u1'] = 'on';
    final auth = _FakeAuth(answers: [false, true]);
    await tester.pumpWidget(_app(await _state(role: 'patient'), auth, PatientLock()));
    await tester.pumpAndSettle();
    expect(auth.asked, 1, reason: 'asked as the app opens');
    expect(find.text('Steady is locked'), findsOneWidget);
    expect(find.text('home'), findsNothing, reason: 'nothing behind the lock shows');
    expect(find.textContaining('SADAG Suicide Crisis Line'), findsOneWidget);
    expect(find.text('0800 567 567'), findsOneWidget);
    expect(find.text('112'), findsOneWidget);
    // the numbers can be selected (the lock sits above the app's navigator, with its own Overlay)
    await tester.longPress(find.text('0800 567 567'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // and copied, as on other patient screens
    await tester.tap(find.textContaining('SADAG Suicide Crisis Line'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('0800 567 567 copied'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(auth.asked, 2);
    expect(find.text('home'), findsOneWidget);
    expect(find.text('Steady is locked'), findsNothing);
  });

  testWidgets('after signing in with the password, the patient is not asked again', (tester) async {
    _stored['steady.patientlock.u1'] = 'on';
    final auth = _FakeAuth();
    final state = await _state();
    await tester.pumpWidget(_app(state, auth, PatientLock()));
    await tester.pumpAndSettle();
    _signIn(state, 'patient');
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect(auth.asked, 0);
  });

  testWidgets('it locks again after two minutes away, not after one', (tester) async {
    _stored['steady.patientlock.u1'] = 'on';
    var now = DateTime(2026, 11, 3, 10);
    final auth = _FakeAuth(answers: [true]);
    await tester.pumpWidget(_app(await _state(role: 'patient'), auth, PatientLock(), now: () => now));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    await _lifecycle(tester, AppLifecycleState.paused);
    now = now.add(const Duration(minutes: 1));
    await _lifecycle(tester, AppLifecycleState.resumed);
    expect(find.text('home'), findsOneWidget);
    expect(auth.asked, 1);
    await _lifecycle(tester, AppLifecycleState.paused);
    now = now.add(const Duration(minutes: 3));
    await _lifecycle(tester, AppLifecycleState.resumed);
    expect(auth.asked, 2);
    expect(find.text('Steady is locked'), findsOneWidget);
    expect(find.text('home'), findsNothing);
    expect(find.text('0800 567 567'), findsOneWidget);
  });

  testWidgets('a phone whose screen lock was removed says so and lets the patient in, with the lock turned off', (tester) async {
    _stored['steady.patientlock.u1'] = 'on';
    final auth = _FakeAuth(hasLock: false);
    final lock = PatientLock();
    await tester.pumpWidget(_app(await _state(role: 'patient'), auth, lock));
    await tester.pumpAndSettle();
    expect(find.textContaining('no longer has a screen lock'), findsOneWidget);
    expect(find.text('0800 567 567'), findsOneWidget);
    await tester.tap(find.text('Open Steady'));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect(lock.isOn('u1'), isFalse);
    expect(_stored.containsKey('steady.patientlock.u1'), isFalse);
    expect(auth.asked, 0);
  });

  testWidgets('staff phones are locked when the app opens, whatever the patient setting', (tester) async {
    final auth = _FakeAuth(answers: [false, true]);
    await tester.pumpWidget(_app(await _state(role: 'clinician'), auth, PatientLock()));
    await tester.pumpAndSettle();
    expect(find.text('Steady is locked'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.text('home'), findsNothing);
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('a session that runs out while the app is open stays locked (its screens are still there)', (tester) async {
    var now = DateTime(2026, 11, 3, 10);
    final auth = _FakeAuth(answers: [true]);
    final state = await _state(role: 'clinician');
    await tester.pumpWidget(_app(state, auth, PatientLock(), now: () => now));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    // days later, still in memory: the token has run out
    _signIn(state, 'clinician', exp: 1000);
    expect(state.signedIn, isFalse);
    await _lifecycle(tester, AppLifecycleState.paused);
    now = now.add(const Duration(days: 6));
    await _lifecycle(tester, AppLifecycleState.resumed);
    expect(find.text('Steady is locked'), findsOneWidget);
    expect(find.text('home'), findsNothing);
  });

  testWidgets('staff told the phone has no screen lock can set one and try again', (tester) async {
    final auth = _FakeAuth(hasLock: false, answers: [true]);
    await tester.pumpWidget(_app(await _state(role: 'clinician'), auth, PatientLock()));
    await tester.pumpAndSettle();
    expect(find.textContaining('This phone has no screen lock'), findsOneWidget);
    auth.hasLock = true;
    await tester.tap(find.text('I\'ve set one: try again'));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });

  test('the setting is kept per account, on the phone only', () async {
    final lock = PatientLock();
    expect(lock.isOn('a'), isNull, reason: 'not read yet');
    await lock.load('a');
    expect(lock.isOn('a'), isFalse, reason: 'off unless turned on');
    await lock.set('a', true);
    expect(_stored['steady.patientlock.a'], 'on');
    final again = PatientLock();
    await again.load('a');
    await again.load('b');
    expect(again.isOn('a'), isTrue);
    expect(again.isOn('b'), isFalse);
    await again.set('a', false);
    expect(_stored.containsKey('steady.patientlock.a'), isFalse);
  });
}
