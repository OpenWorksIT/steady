// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:steady/models.dart';
import 'package:steady/ui/brand.dart';

void main() {
  test('the practice brand comes from the server config', () {
    final c = AppConfig.fromJson({
      'practiceName': 'VR Clinical Psychology',
      'crisisLines': [],
      'brand': {'tagline': 'Scientific practice, authentic care.', 'accent': '#B0690C', 'logo': '/api/steady/brand/logo?v=1'},
    });
    expect(c.practiceName, 'VR Clinical Psychology');
    expect(c.brandTagline, 'Scientific practice, authentic care.');
    expect(c.brandAccent, '#B0690C');
    expect(c.brandLogo, '/api/steady/brand/logo?v=1');
  });

  test('without a brand the app is plain Steady', () {
    final c = AppConfig.fromJson({'crisisLines': []});
    expect([c.brandTagline, c.brandAccent, c.brandLogo], ['', '', '']);
    expect(AppConfig.fallback().brandLogo, '');
  });

  test('accent colours are read strictly', () {
    expect(Brand.parseHex('#B0690C'), const Color(0xFFB0690C));
    expect(Brand.parseHex('red'), isNull);
    expect(Brand.parseHex('#B0690C;x'), isNull);
  });
}
