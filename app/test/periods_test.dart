// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:steady/models.dart';
import 'package:steady/ui/wearable/periods.dart';
import 'package:steady/wearable/metrics.dart';

void main() {
  final wed = DateTime(2026, 10, 14);

  test('week runs Monday to Sunday', () {
    final p = Period.containing(Span.week, wed);
    expect(p.start, DateTime(2026, 10, 12));
    expect(p.end, DateTime(2026, 10, 18));
    expect(p.groups().length, 7);
    expect(p.shift(-1).start, DateTime(2026, 10, 5));
  });

  test('month is the calendar month', () {
    final p = Period.containing(Span.month, DateTime(2028, 2, 10));
    expect(p.start, DateTime(2028, 2, 1));
    expect(p.end, DateTime(2028, 2, 29));
    expect(p.groups().length, 29);
    expect(p.shift(1).start, DateTime(2028, 3, 1));
    expect(p.title, 'February 2028');
  });

  test('six months is 26 weeks ending this week', () {
    final p = Period.containing(Span.sixMonths, wed);
    expect(p.groups().length, 26);
    expect(p.end, DateTime(2026, 10, 18));
    expect(p.groups().every((g) => g.$2.length == 7), isTrue);
  });

  test('year is 12 months ending this month', () {
    final p = Period.containing(Span.year, wed);
    expect(p.start, DateTime(2025, 11, 1));
    expect(p.end, DateTime(2026, 10, 31));
    expect(p.groups().length, 12);
    expect(p.groups().first.$1, 'Nov');
  });

  test('weekly points average the days that have data, with the usual range', () {
    final data = Biometrics.fromJson({
      'from': '2026-10-12',
      'to': '2026-10-18',
      'days': [
        {'day': '2026-10-12', 'values': {'rhr': 60, 'hr_min': 50, 'hr_max': 120, 'hr_avg': 70}},
        {'day': '2026-10-13', 'values': {'rhr': 62}},
      ],
      'baseline': {
        'rhr': [
          {'day': '2026-10-12', 'lo': 55, 'mid': 60, 'hi': 65, 'n': 10},
          {'day': '2026-10-13', 'lo': 57, 'mid': 61, 'hi': 67, 'n': 11},
        ],
      },
    });
    final rhr = wearableMetrics.firstWhere((m) => m.key == 'rhr');
    final sixMonths = Period(Span.sixMonths, DateTime(2026, 10, 12), DateTime(2026, 10, 18));
    final pts = chartPoints(data, rhr, sixMonths);
    expect(pts.length, 1);
    expect(pts.single.value, 61);
    expect(pts.single.bandLo, 56);
    expect(pts.single.bandHi, 66);

    final week = chartPoints(data, wearableMetrics.firstWhere((m) => m.key == 'hr_avg'), Period(Span.week, DateTime(2026, 10, 12), DateTime(2026, 10, 18)));
    expect(week.first.low, 50);
    expect(week.first.high, 120);
    expect(week[1].hasValue, isFalse);
  });

  test('formatting', () {
    expect(formatMinutes(452), '7h 32m');
    expect(formatMinutes(45), '45m');
    expect(formatSteps(12345), '12,345');
    expect(formatClock(-75), '22:45');
    expect(formatClock(390), '06:30');
  });
}
