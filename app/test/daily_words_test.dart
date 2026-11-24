// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:steady/content/daily_words.dart';

final _stored = <String, String>{};

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
      }
      return null;
    });
  });

  test('there are 60 built-in daily words, all different and short enough for one screen', () {
    expect(dailyWords.length, 60);
    expect(dailyWords.toSet().length, 60);
    expect(dailyWords.every((w) => w.length <= 120), isTrue);
  });

  test('the words stay the same all day and change the next day, cycling through every one', () {
    final morning = wordsForToday(const [], now: DateTime(2026, 10, 22, 7));
    expect(wordsForToday(const [], now: DateTime(2026, 10, 22, 22)), morning);
    expect(wordsForToday(const [], now: DateTime(2026, 10, 23, 7)), isNot(morning));
    final seen = {for (var i = 0; i < 60; i++) wordsForToday(const [], now: DateTime(2026, 1, 1).add(Duration(days: i)))};
    expect(seen.length, 60);
  });

  test("a clinician's own words join the rotation", () {
    final own = ['Remember the plan we made.'];
    final seen = {for (var i = 0; i < 61; i++) wordsForToday(own, now: DateTime(2026, 1, 1).add(Duration(days: i)))};
    expect(seen, contains(own.first));
  });

  // Kempie van Rooyen's review (November 2026): nothing predicts how someone will feel, and the
  // body-focused prompts are invitations with an alternative
  test('no line promises how someone will feel; breathing and body prompts are offered, with another way', () {
    for (final gone in ['Beginning is how ready arrives', 'This one will change too', 'Rough days end', 'better than your worries say',
        'more patience in you than you think', 'It means you keep going', "That's all.", 'let the rest wait', 'You don\'t have to keep them forever']) {
      expect(dailyWords.where((w) => w.contains(gone)), isEmpty, reason: gone);
    }
    final body = dailyWords.where((w) => RegExp(r'breath|jaw|shoulders|feet', caseSensitive: false).hasMatch(w) && w != 'One breath at a time is enough.');
    expect(body.length, 5);
    for (final w in body) {
      expect(w, matches(RegExp(r"^If (it|you)")), reason: w);
      expect(w, contains('. Or '), reason: w);
    }
  });

  test('a hidden line is never shown again, and with every line hidden there are no words', () {
    final day = DateTime(2026, 3, 5);
    final first = wordsForToday(const [], now: day);
    final next = wordsForToday(const [], now: day, hidden: {first});
    expect(next, isNot(first));
    expect({for (var i = 0; i < 90; i++) wordsForToday(const [], now: day.add(Duration(days: i)), hidden: {first})}, isNot(contains(first)));
    expect(wordsForToday(const [], hidden: dailyWords.toSet()), '');
  });

  test("a patient's choices are kept on the phone, per account", () async {
    final prefs = DailyWordsPrefs();
    await prefs.load('u1');
    expect(prefs.isOff('u1'), isFalse);
    expect(prefs.hidden('u1'), isEmpty);
    await prefs.hide('u1', dailyWords[3]);
    await prefs.setOff('u1', true);
    final again = DailyWordsPrefs();
    await again.load('u1');
    expect(again.isOff('u1'), isTrue);
    expect(again.hidden('u1'), {dailyWords[3]});
    await again.load('u2');
    expect(again.hidden('u2'), isEmpty, reason: 'another account on the same phone');
    await again.showAll('u1');
    final third = DailyWordsPrefs();
    await third.load('u1');
    expect(third.hidden('u1'), isEmpty);
  });
}
