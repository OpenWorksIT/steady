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

  test('SADAG and 112 are always shown first, whatever the server sends', () {
    List<String> numbers(AppConfig c) => c.crisisLines.map((l) => l.number).toList();
    expect(numbers(AppConfig.fromJson({'crisisLines': []})), ['0800 567 567', '112']);
    expect(numbers(AppConfig.fallback()), ['0800 567 567', '112']);
    final c = AppConfig.fromJson({
      'crisisLines': [
        {'label': 'Emergency', 'number': '112', 'hours': '24 hours'},
        {'label': 'Practice after hours', 'number': '+27 21 555 0100', 'hours': 'evenings'},
        {'label': '', 'number': '0800 000 000', 'hours': ''},
      ],
    });
    expect(numbers(c), ['0800 567 567', '112', '+27 21 555 0100']);
    expect(AppConfig.fromJson({'crisisLines': [], 'crisisNotice': ''}).crisisNotice, isNotEmpty);
  });

  test('accent colours are read strictly', () {
    expect(Brand.parseHex('#B0690C'), const Color(0xFFB0690C));
    expect(Brand.parseHex('red'), isNull);
    expect(Brand.parseHex('#B0690C;x'), isNull);
  });
}
