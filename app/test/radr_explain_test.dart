// SPDX-License-Identifier: AGPL-3.0-or-later
//
// RADR one tap down: the server's explanation of a day (test/fixtures/radr_explain.json, made by
// server/pb_hooks/lib/radr.js explain() for the fictional demo patient B) shown in plain words,
// with the data behind each number and each flag's review.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:steady/models.dart';
import 'package:steady/ui/clinician/radr_explain.dart';
import 'package:steady/ui/theme.dart';

Map<String, dynamic> fixture() => jsonDecode(File('test/fixtures/radr_explain.json').readAsStringSync()) as Map<String, dynamic>;

Future<void> show(WidgetTester tester, Widget body) async {
  tester.view.physicalSize = const Size(1200, 6000);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: Scaffold(body: body)));
  await tester.pumpAndSettle();
}

void main() {
  test('RADR values and days read as people read them', () {
    expect(radrDay('2026-11-02'), 'Mon 2 Nov');
    expect(radrValue('sleep_min', 425), '7 h 05');
    expect(radrValue('sleep_min', 45), '45 min');
    expect(radrValue('midpoint', -30), '23:30');
    expect(radrValue('midpoint', 1500), '01:00');
    expect(radrValue('steps', 6200.4), '6200 steps');
    expect(radrValue('rhr', 61.66), '61.7 bpm');
    expect(radrValue('mood', 2), '2.0 of 5');
    expect(radrValue('steps', null), '-');
    expect(reviewedText(FlagReview('Dr Demo', DateTime(2026, 11, 2, 9), '')), 'Reviewed by Dr Demo, 2 Nov 2026');
  });

  testWidgets('the whole day: the server\'s words, each flag with its review, and the areas', (tester) async {
    final x = fixture();
    final reviewed = <String>[];
    await show(tester, RadrExplainBody(x: x, onReview: (f) => reviewed.add('${f['key']}')));
    expect(find.text(radrDay('${x['day']}')), findsOneWidget);
    expect(find.textContaining('to improve care'), findsOneWidget);
    expect(find.text('${x['words']}'), findsOneWidget);
    // the first flag was reviewed: who and when, with the note; the others can be marked
    expect(find.textContaining('Reviewed by Dr Démo, 2 Nov 2026: Spoke on the phone.'), findsOneWidget);
    expect(find.text('Mark as reviewed'), findsNWidgets((x['flags'] as List).length - 1));
    await tester.tap(find.text('Mark as reviewed').first);
    expect(reviewed, ['${(x['flags'] as List)[1]['key']}']);
    // nothing reads as an alarm
    expect(find.textContaining(RegExp('alert|alarm|risk level', caseSensitive: false)), findsNothing);
  });

  testWidgets('one area opens first, with each measure\'s words, why it counts and the data behind it', (tester) async {
    final x = fixture();
    await show(tester, RadrExplainBody(x: x, focus: 'activity'));
    final steps = (x['measures'] as Map)['steps'] as Map;
    expect(find.text('${steps['words']}'), findsOneWidget);
    expect(find.textContaining('Why it counts: ${steps['why']}'), findsOneWidget);
    // and the whole day further down
    expect(find.text('The whole day'), findsOneWidget);
    await tester.tap(find.text('The data behind it').first);
    await tester.pumpAndSettle();
    final base = steps['baseline'] as Map;
    expect(find.textContaining('Their usual is the middle of these ${(base['values'] as List).length} values'), findsOneWidget);
    final last = (steps['window'] as List).last as Map;
    expect(find.text('${radrDay('${last['day']}')}: ${radrValue('steps', last['value'])}'), findsOneWidget);
  });

  testWidgets('without a review action (an earlier day), no button', (tester) async {
    final x = fixture()..['flags'] = <Object>[];
    await show(tester, RadrExplainBody(x: x));
    expect(find.text('Mark as reviewed'), findsNothing);
  });
}
