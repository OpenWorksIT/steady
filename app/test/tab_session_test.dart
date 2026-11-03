// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:steady/services/tab_session.dart';

String _token(Map<String, Object> claims) {
  String part(Map<String, Object> m) => base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${part({'alg': 'HS256', 'typ': 'JWT'})}.${part(claims)}.signature';
}

void main() {
  test('reads when a token runs out', () {
    final exp = DateTime.utc(2026, 11, 3, 11);
    expect(tokenExpiry(_token({'id': 'x', 'exp': exp.millisecondsSinceEpoch ~/ 1000, 'steadyTab': true})), exp);
    expect(tokenExpiry(_token({'id': 'x'})), isNull);
    expect(tokenExpiry(''), isNull);
    expect(tokenExpiry('not.a.token'), isNull);
    expect(tokenExpiry('one-part'), isNull);
  });

  test('an hour-long token is renewed after 20 minutes, leaving 40 for a sleeping computer or a lost connection', () {
    final now = DateTime.utc(2026, 11, 3, 10);
    expect(renewAfter(now.add(const Duration(hours: 1)), now), const Duration(minutes: 20));
    // each renewal gives a new hour, so a tab that stays open is never signed out
    expect(renewAfter(now.add(const Duration(minutes: 40)), now), const Duration(minutes: 13, seconds: 20));
  });

  test('a token about to run out is renewed straight away; one that has run out, not at all', () {
    final now = DateTime.utc(2026, 11, 3, 10);
    expect(renewAfter(now.add(const Duration(seconds: 12)), now), const Duration(seconds: 5));
    expect(renewAfter(now.add(const Duration(seconds: 3)), now), Duration.zero);
    expect(renewAfter(now, now), Duration.zero);
    expect(renewAfter(now.subtract(const Duration(minutes: 5)), now), Duration.zero);
  });

  test('a long token (a phone, or a session from before) waits a long time', () {
    final now = DateTime.utc(2026, 11, 3, 10);
    expect(renewAfter(now.add(const Duration(days: 5)), now), const Duration(hours: 40));
  });
}
