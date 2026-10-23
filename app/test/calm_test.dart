// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:steady/ui/calm.dart';
import 'package:steady/ui/theme.dart';

void main() {
  test('patients get slow page transitions on every platform', () {
    final t = withCalmTransitions(buildTheme(Brightness.light));
    for (final p in TargetPlatform.values) {
      final b = t.pageTransitionsTheme.builders[p];
      expect(b, isA<CalmPageTransitionsBuilder>(), reason: '$p');
      expect(b!.transitionDuration, calmIn);
      expect(b.reverseTransitionDuration, calmOut);
    }
  });

  test('staff keep the normal theme', () {
    expect(buildTheme(Brightness.light).pageTransitionsTheme.builders.values.whereType<CalmPageTransitionsBuilder>(), isEmpty);
  });

  testWidgets('a page pushed with the calm theme takes its time', (tester) async {
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      theme: withCalmTransitions(buildTheme(Brightness.light)),
      navigatorKey: key,
      home: const Text('home'),
    ));
    key.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('next'))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    // halfway through: still dissolving
    final fade = tester.widgetList<FadeTransition>(find.ancestor(of: find.text('next'), matching: find.byType(FadeTransition)));
    expect(fade.any((f) => f.opacity.value > 0 && f.opacity.value < 1), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('next'), findsOneWidget);
  });

  testWidgets('calm dialogs fade in over most of a second', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) => TextButton(
            onPressed: () => showCalmDialog<void>(context: context, builder: (_) => const AlertDialog(title: Text('A new version'))),
            child: const Text('open'),
          )),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final fade = tester.widgetList<FadeTransition>(find.ancestor(of: find.text('A new version'), matching: find.byType(FadeTransition)));
    expect(fade.any((f) => f.opacity.value > 0 && f.opacity.value < 1), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('A new version'), findsOneWidget);
  });
}
