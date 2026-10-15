// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Turns raw watch readings into one summary per day, on the phone. Only these daily
// summaries are uploaded. The same rules run for every brand, so values compare across
// Samsung, Apple and others.
//
// Resting heart rate (rhr-v1): the lowest average over any 30-minute stretch of that night's
// sleep (at least 3 readings spanning 10+ minutes). With no sleep record, the lowest such
// stretch across the day is used and marked "awake".

const rhrAlgorithm = 'rhr-v1';

class HrSample {
  final DateTime t;
  final double bpm;
  const HrSample(this.t, this.bpm);
}

enum SleepStage { session, asleep, light, deep, rem, awake, inBed }

class SleepSegment {
  final DateTime start, end;
  final SleepStage stage;
  const SleepSegment(this.start, this.end, this.stage);
  Duration get length => end.difference(start);
}

class SpO2Sample {
  final DateTime t;
  final double percent;
  const SpO2Sample(this.t, this.percent);
}

/// Everything read from the phone's health store that is needed to summarise one day.
/// [hr] should start at least 12 hours before [dayStart] so overnight sleep is covered.
class DayReadings {
  final DateTime dayStart; // local midnight
  final List<HrSample> hr;
  final List<SleepSegment> sleep;
  final List<SpO2Sample> spo2;
  final int? steps;
  const DayReadings({required this.dayStart, this.hr = const [], this.sleep = const [], this.spo2 = const [], this.steps});
  DateTime get dayEnd => DateTime(dayStart.year, dayStart.month, dayStart.day + 1);
}

String dayKey(DateTime local) =>
    '${local.year.toString().padLeft(4, '0')}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';

double _r1(double v) => (v * 10).roundToDouble() / 10;

/// Lowest mean heart rate over any [window]-long stretch, or null if no stretch qualifies.
double? restingHeartRate(
  List<HrSample> samples, {
  Duration window = const Duration(minutes: 30),
  int minSamples = 3,
  Duration minSpan = const Duration(minutes: 10),
}) {
  if (samples.length < minSamples) return null;
  final s = [...samples]..sort((a, b) => a.t.compareTo(b.t));
  double? best;
  var j = 0;
  var sum = 0.0;
  for (var i = 0; i < s.length; i++) {
    if (j < i) {
      j = i;
      sum = 0;
    }
    final limit = s[i].t.add(window);
    while (j < s.length && s[j].t.isBefore(limit)) {
      sum += s[j].bpm;
      j++;
    }
    final count = j - i;
    if (count >= minSamples && s[j - 1].t.difference(s[i].t) >= minSpan) {
      final mean = sum / count;
      if (best == null || mean < best) best = mean;
    }
    sum -= s[i].bpm;
  }
  return best == null ? null : _r1(best);
}

/// Sessions from explicit session records, or built by joining stage segments less than an
/// hour apart (Apple Health stores stages without a session).
List<SleepSegment> sleepSessions(List<SleepSegment> segments) {
  final explicit = segments.where((s) => s.stage == SleepStage.session).toList();
  if (explicit.isNotEmpty) return explicit..sort((a, b) => a.start.compareTo(b.start));
  final parts = segments.where((s) => s.stage != SleepStage.inBed).toList()..sort((a, b) => a.start.compareTo(b.start));
  final out = <SleepSegment>[];
  for (final p in parts) {
    if (out.isNotEmpty && p.start.difference(out.last.end) < const Duration(hours: 1)) {
      final last = out.removeLast();
      out.add(SleepSegment(last.start, p.end.isAfter(last.end) ? p.end : last.end, SleepStage.session));
    } else {
      out.add(SleepSegment(p.start, p.end, SleepStage.session));
    }
  }
  return out;
}

int _overlapMinutes(SleepSegment a, SleepSegment b) {
  final start = a.start.isAfter(b.start) ? a.start : b.start;
  final end = a.end.isBefore(b.end) ? a.end : b.end;
  return end.isAfter(start) ? end.difference(start).inMinutes : 0;
}

/// The daily summary uploaded to the server. Keys match server/pb_hooks/lib/wearable.js.
Map<String, Object> summariseDay(DayReadings r) {
  final out = <String, Object>{};
  final start = r.dayStart, end = r.dayEnd;
  bool inDay(DateTime t) => !t.isBefore(start) && t.isBefore(end);

  // heart rate for the calendar day
  final dayHr = r.hr.where((s) => inDay(s.t)).toList();
  if (dayHr.isNotEmpty) {
    var min = dayHr.first.bpm, max = dayHr.first.bpm, sum = 0.0;
    for (final s in dayHr) {
      if (s.bpm < min) min = s.bpm;
      if (s.bpm > max) max = s.bpm;
      sum += s.bpm;
    }
    out['hr_min'] = _r1(min);
    out['hr_max'] = _r1(max);
    out['hr_avg'] = _r1(sum / dayHr.length);
    out['hr_samples'] = dayHr.length;
  }

  // sleep that ended on this day (last night's sleep, and any naps)
  final sessions = sleepSessions(r.sleep).where((s) => inDay(s.end)).toList();
  if (sessions.isNotEmpty) {
    final stages = r.sleep.where((s) => s.stage != SleepStage.session && s.stage != SleepStage.inBed).toList();
    var light = 0, deep = 0, rem = 0, asleep = 0, awake = 0;
    for (final sess in sessions) {
      for (final st in stages) {
        final m = _overlapMinutes(sess, st);
        if (m == 0) continue;
        switch (st.stage) {
          case SleepStage.light:
            light += m;
          case SleepStage.deep:
            deep += m;
          case SleepStage.rem:
            rem += m;
          case SleepStage.asleep:
            asleep += m;
          case SleepStage.awake:
            awake += m;
          default:
            break;
        }
      }
    }
    final staged = light + deep + rem + asleep;
    final total = staged > 0
        ? staged
        : sessions.fold<int>(0, (a, s) => a + s.length.inMinutes) - awake;
    if (total > 0) out['sleep_min'] = total;
    if (light > 0) out['sleep_light'] = light;
    if (deep > 0) out['sleep_deep'] = deep;
    if (rem > 0) out['sleep_rem'] = rem;
    if (awake > 0) out['sleep_awake'] = awake;
    final main = sessions.reduce((a, b) => b.length > a.length ? b : a);
    out['sleep_onset'] = main.start.difference(start).inMinutes;
    out['sleep_wake'] = main.end.difference(start).inMinutes;

    final asleepHr = r.hr.where((h) => sessions.any((s) => !h.t.isBefore(s.start) && h.t.isBefore(s.end))).toList();
    final rhr = restingHeartRate(asleepHr);
    if (rhr != null) {
      out['rhr'] = rhr;
      out['rhr_method'] = 'sleep';
    }
  }
  if (!out.containsKey('rhr')) {
    final rhr = restingHeartRate(dayHr);
    if (rhr != null) {
      out['rhr'] = rhr;
      out['rhr_method'] = 'awake';
    }
  }

  // blood oxygen (Apple reports a fraction, Health Connect a percentage)
  final ox = r.spo2.where((s) => inDay(s.t)).map((s) => s.percent <= 1.5 ? s.percent * 100 : s.percent).toList();
  if (ox.isNotEmpty) {
    out['spo2_avg'] = _r1(ox.reduce((a, b) => a + b) / ox.length);
    out['spo2_min'] = _r1(ox.reduce((a, b) => a < b ? a : b));
  }

  if (r.steps != null && r.steps! >= 0) out['steps'] = r.steps!;
  return out;
}
