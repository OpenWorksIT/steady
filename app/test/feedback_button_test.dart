// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:steady/feedback/feedback.dart';
import 'package:steady/ui/theme.dart';

void main() {
  // The button lives in MaterialApp.builder, above the navigator, exactly as in the app.
  Widget app(GlobalKey<NavigatorState> key) => MaterialApp(
        theme: buildTheme(Brightness.light),
        navigatorKey: key,
        builder: (context, child) => Stack(children: [
          child!,
          Positioned(left: 6, bottom: 92, child: FeedbackButton(navigatorKey: key)),
        ]),
        home: const Scaffold(body: Text('screen')),
      );

  testWidgets('hovering the Feedback button shows its hint and nothing breaks', (tester) async {
    await tester.pumpWidget(app(GlobalKey<NavigatorState>()));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byIcon(Icons.feedback_outlined)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Feedback or a bug'), findsOneWidget);
    expect(find.text('screen'), findsOneWidget);
    await mouse.moveTo(const Offset(300, 100));
    await tester.pumpAndSettle();
    expect(find.text('Feedback or a bug'), findsNothing);
  });

  testWidgets('a long press on the Feedback button opens the feedback sheet like a tap', (tester) async {
    final errors = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (d) => errors.add(d.toString().split('\n').take(30).join(' | '));
    addTearDown(() => FlutterError.onError = previous);
    await tester.pumpWidget(app(GlobalKey<NavigatorState>()));
    await tester.longPress(find.byIcon(Icons.feedback_outlined));
    await tester.pumpAndSettle();
    FlutterError.onError = previous;
    expect(errors, isEmpty, reason: errors.isEmpty ? null : errors.first);
    expect(find.text('Bug found'), findsOneWidget);
    expect(find.text('screen'), findsOneWidget);
  });
}
