// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:steady/wearable/summary.dart';

void main() {
  final day = DateTime(2026, 10, 15);
  List<HrSample> every(DateTime from, DateTime to, Duration step, double Function(DateTime) bpm) {
    final out = <HrSample>[];
    for (var t = from; t.isBefore(to); t = t.add(step)) {
      out.add(HrSample(t, bpm(t)));
    }
    return out;
  }

  test('day keys', () {
    expect(dayKey(DateTime(2026, 3, 7, 23, 59)), '2026-03-07');
  });

  test('resting heart rate is the lowest 30-minute average', () {
    final samples = every(day, day.add(const Duration(hours: 3)), const Duration(minutes: 5), (t) {
      final m = t.difference(day).inMinutes;
      return (m >= 60 && m < 95) ? 50 : 70; // a 35-minute calm stretch at 01:00
    });
    expect(restingHeartRate(samples), 50.0);
  });

  test('a single low reading does not count as resting', () {
    final samples = every(day, day.add(const Duration(hours: 2)), const Duration(minutes: 10), (_) => 65)
      ..add(HrSample(day.add(const Duration(minutes: 33)), 40));
    expect(restingHeartRate(samples)! > 55, isTrue);
  });

  test('too few readings give no resting heart rate', () {
    expect(restingHeartRate([HrSample(day, 60), HrSample(day.add(const Duration(minutes: 1)), 60)]), isNull);
    expect(restingHeartRate([]), isNull);
  });

  test('sleep, stages and resting heart rate from last night', () {
    final bed = day.subtract(const Duration(minutes: 75)); // 22:45 the evening before
    final up = day.add(const Duration(hours: 6, minutes: 30)); // 06:30
    final r = DayReadings(
      dayStart: day,
      hr: [
        ...every(day.subtract(const Duration(hours: 4)), bed, const Duration(minutes: 10), (_) => 72),
        ...every(bed, up, const Duration(minutes: 10), (t) => t.hour == 3 ? 52 : 58),
        ...every(up, day.add(const Duration(hours: 20)), const Duration(minutes: 10), (_) => 80),
      ],
      sleep: [
        SleepSegment(bed, up, SleepStage.session),
        SleepSegment(bed, bed.add(const Duration(minutes: 15)), SleepStage.awake),
        SleepSegment(bed.add(const Duration(minutes: 15)), day.add(const Duration(hours: 2)), SleepStage.light),
        SleepSegment(day.add(const Duration(hours: 2)), day.add(const Duration(hours: 4)), SleepStage.deep),
        SleepSegment(day.add(const Duration(hours: 4)), up, SleepStage.rem),
      ],
      spo2: [SpO2Sample(day.add(const Duration(hours: 3)), 95), SpO2Sample(day.add(const Duration(hours: 4)), 97)],
      steps: 8123,
    );
    final s = summariseDay(r);
    expect(s['sleep_awake'], 15);
    expect(s['sleep_light'], 180); // 23:00 to 02:00
    expect(s['sleep_deep'], 120);
    expect(s['sleep_rem'], 150);
    expect(s['sleep_min'], 450);
    expect(s['sleep_onset'], -75);
    expect(s['sleep_wake'], 390);
    expect(s['rhr'], 52.0);
    expect(s['rhr_method'], 'sleep');
    expect(s['spo2_avg'], 96.0);
    expect(s['spo2_min'], 95.0);
    expect(s['steps'], 8123);
    expect(s['hr_max'], 80.0);
    expect(s['hr_min'], 52.0);
  });

  test('without sleep, resting heart rate comes from the day and is marked awake', () {
    final s = summariseDay(DayReadings(
      dayStart: day,
      hr: every(day.add(const Duration(hours: 9)), day.add(const Duration(hours: 12)), const Duration(minutes: 5), (_) => 66),
    ));
    expect(s['rhr'], 66.0);
    expect(s['rhr_method'], 'awake');
    expect(s.containsKey('sleep_min'), isFalse);
  });

  test('Apple-style stages without a session are joined into one night', () {
    final s = summariseDay(DayReadings(dayStart: day, sleep: [
      SleepSegment(day.add(const Duration(minutes: 10)), day.add(const Duration(hours: 3)), SleepStage.asleep),
      SleepSegment(day.add(const Duration(hours: 3, minutes: 20)), day.add(const Duration(hours: 7)), SleepStage.asleep),
      SleepSegment(day.add(const Duration(hours: 14)), day.add(const Duration(hours: 14, minutes: 30)), SleepStage.asleep),
    ]));
    expect(s['sleep_min'], 170 + 220 + 30);
    expect(s['sleep_onset'], 10, reason: 'main sleep, not the nap');
    expect(s['sleep_wake'], 420);
  });

  test('sleep that ends tomorrow is not counted today', () {
    final s = summariseDay(DayReadings(dayStart: day, sleep: [
      SleepSegment(day.add(const Duration(hours: 23)), day.add(const Duration(hours: 31)), SleepStage.session),
    ]));
    expect(s.containsKey('sleep_min'), isFalse);
  });

  test('blood oxygen fractions are converted to percent', () {
    final s = summariseDay(DayReadings(dayStart: day, spo2: [SpO2Sample(day.add(const Duration(hours: 1)), 0.96)]));
    expect(s['spo2_avg'], 96.0);
  });

  test('an empty day gives an empty summary', () {
    expect(summariseDay(DayReadings(dayStart: day)), isEmpty);
  });
}
