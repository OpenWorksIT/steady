// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:steady/content/daily_words.dart';

void main() {
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

  test("a psychologist's own words join the rotation", () {
    final own = ['Remember the plan we made.'];
    final seen = {for (var i = 0; i < 61; i++) wordsForToday(own, now: DateTime(2026, 1, 1).add(Duration(days: i)))};
    expect(seen, contains(own.first));
  });
}
