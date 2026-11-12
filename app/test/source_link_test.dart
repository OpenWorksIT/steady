// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:steady/ui/source_link.dart';
import 'package:steady/ui/theme.dart';

void main() {
  // Google Play's health policy: health apps say they aren't a medical device (1.2.3). The
  // footer under the sign-in form and in Settings carries it.
  testWidgets('the footer says Steady is not a medical device, above who made it', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: const Scaffold(body: SourceLink()),
    ));
    expect(find.text(kNotMedicalDevice), findsOneWidget);
    expect(kNotMedicalDevice, contains('not a medical device and does not diagnose, treat, cure, or prevent any medical condition'));
    expect(find.textContaining('free software (AGPL-3.0)'), findsOneWidget);
    expect(tester.getTopLeft(find.text(kNotMedicalDevice)).dy,
        lessThan(tester.getTopLeft(find.textContaining('free software (AGPL-3.0)')).dy));
    expect(find.text('Source code'), findsOneWidget);
  });
}
