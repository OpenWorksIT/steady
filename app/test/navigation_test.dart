// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Where things are: a psychologist's bottom bar is Patients, Alerts and (when the server has it)
// Community; a practice admin's is People and Community, or no bar without the community; the
// gear opens Settings as a page; Settings > Practice holds the library and the practice's own
// business, each for whoever had it before.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:steady/app_state.dart';
import 'package:steady/models.dart';
import 'package:steady/services/api.dart';
import 'package:steady/ui/clinician/clinician_shell.dart';
import 'package:steady/ui/practice/admin_shell.dart';
import 'package:steady/ui/practice/practice_screen.dart';
import 'package:steady/ui/settings_screen.dart';
import 'package:steady/ui/theme.dart';

// secure storage, in memory (the session)
final _stored = <String, String>{};

String _token() {
  String part(Map<String, Object> m) => base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${part({'alg': 'HS256', 'typ': 'JWT'})}.${part({'id': 'u1', 'type': 'auth', 'exp': 4102444800})}.sig';
}

Future<AppState> _signedIn(String role, {bool master = false}) async {
  final state = AppState(await Api.create());
  state.api.pb.authStore.save(
      _token(),
      RecordModel.fromJson({
        'id': 'u1',
        'collectionId': '_pb_users_auth_',
        'collectionName': 'users',
        'role': role,
        'master': master,
        'name': 'Sam',
        'email': 'sam@example.org',
      }));
  return state;
}

Widget _app(AppState state, Widget home) =>
    AppScope(state: state, child: MaterialApp(theme: buildTheme(Brightness.light), home: home));

/// The rows of the page on top (Settings > Practice).
List<String> _rows(WidgetTester tester) => tester.widgetList<SettingsLink>(find.byType(SettingsLink)).map((l) => l.title).toList();

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

  testWidgets("a psychologist's tabs are Patients, Alerts and, when the server has it, Community", (tester) async {
    Widget bar({required bool community}) => MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(bottomNavigationBar: NavigationBar(destinations: clinicianTabs(unread: 2, community: community))),
        );
    List<String> labels() => tester.widgetList<NavigationDestination>(find.byType(NavigationDestination)).map((d) => d.label).toList();

    await tester.pumpWidget(bar(community: false));
    expect(labels(), ['Patients', 'Alerts']);
    expect(find.widgetWithText(Badge, '2'), findsOneWidget, reason: 'the unread count stays on Alerts');
    await tester.pumpWidget(bar(community: true));
    expect(labels(), ['Patients', 'Alerts', 'Community']);
  });

  testWidgets("a practice admin's tabs are People and, when the server has it, Community", (tester) async {
    expect(adminTabs(community: false).map((d) => d.label).toList(), ['People'], reason:'one tab: no bar, People is the whole screen');
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(bottomNavigationBar: NavigationBar(destinations: adminTabs(community: true))),
    ));
    expect(tester.widgetList<NavigationDestination>(find.byType(NavigationDestination)).map((d) => d.label).toList(), ['People', 'Community']);
  });

  testWidgets("the practice admin's shell: People first, and Community only when the server has it", (tester) async {
    final state = await _signedIn('admin');
    await tester.pumpWidget(_app(state, const AdminShell()));
    await tester.pump();
    expect(find.byType(NavigationBar), findsNothing, reason: 'no bar without the community');
    expect(find.widgetWithText(AppBar, 'Practice'), findsOneWidget, reason: 'the people stay their first screen');

    state.config = AppConfig.fromJson({'communityUrl': 'https://community.steadyapp.co.za'});
    state.changed();
    await tester.pump();
    expect(tester.widgetList<NavigationDestination>(find.byType(NavigationDestination)).map((d) => d.label).toList(), ['People', 'Community']);
    expect(find.widgetWithText(AppBar, 'Practice'), findsOneWidget, reason: 'still People first');
    expect(find.widgetWithText(AppBar, 'Community'), findsNothing);
    await tester.tap(find.byIcon(Icons.forum_outlined));
    await tester.pump();
    expect(find.widgetWithText(AppBar, 'Community'), findsOneWidget);
  });

  testWidgets('the gear opens Settings as a page with a back button, not a pop-up', (tester) async {
    final state = await _signedIn('clinician');
    await tester.pumpWidget(_app(state, Scaffold(appBar: AppBar(title: const Text('Patients'), actions: const [SettingsButton()]))));
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.widgetWithText(AppBar, 'Settings'), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.text('Sam'), findsOneWidget);
    expect(find.text('Change password'), findsOneWidget);
    expect(find.text('Change email'), findsOneWidget, reason: 'everyone can change their own email');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Patients'), findsOneWidget);
  });

  testWidgets('Settings > Practice: every psychologist has the library, and only what they had before', (tester) async {
    await tester.pumpWidget(_app(await _signedIn('clinician'), const SettingsScreen()));
    expect(find.text('Library and feedback tickets'), findsOneWidget);
    await tester.tap(find.text('Practice'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Practice'), findsOneWidget);
    expect(_rows(tester), ['Library', 'Feedback tickets']);
  });

  testWidgets("the master clinician's Practice also has the people, the audit report and the operator agreement", (tester) async {
    final state = await _signedIn('clinician', master: true);
    await tester.pumpWidget(_app(state, const PracticeScreen()));
    expect(_rows(tester), ['Library', 'People', 'Audit report', 'Feedback tickets', 'Operator agreement']);
    expect(practiceSummary(practiceItems(state.api)), 'Library, people, audit report, feedback tickets and operator agreement');
  });

  testWidgets('the practice admin keeps the audit report, feedback and the operator agreement; the people stay their first screen',
      (tester) async {
    await tester.pumpWidget(_app(await _signedIn('admin'), const PracticeScreen()));
    expect(_rows(tester), ['Audit report', 'Feedback tickets', 'Operator agreement']);
  });

  testWidgets('OpenWorks support keeps the operator agreement (their feedback is their first screen)', (tester) async {
    await tester.pumpWidget(_app(await _signedIn('support'), const PracticeScreen()));
    expect(_rows(tester), ['Operator agreement']);
  });

  testWidgets('patients never see Practice', (tester) async {
    final state = await _signedIn('patient');
    expect(practiceItems(state.api), isEmpty);
    await tester.pumpWidget(_app(state, const SettingsScreen()));
    await tester.pump();
    expect(find.widgetWithText(AppBar, 'Settings'), findsOneWidget);
    expect(find.text('Practice'), findsNothing);
    expect(find.text('Delete my account'), findsOneWidget);
  });
}
