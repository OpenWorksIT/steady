// SPDX-License-Identifier: AGPL-3.0-or-later
// Calendar periods for the clinician's watch-data views, and grouping days into points.
import '../../models.dart';
import '../../wearable/metrics.dart';
import '../../wearable/summary.dart';
import 'wearable_chart.dart';

enum Span { day, week, month, sixMonths, year }

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
DateTime parseDay(String s) {
  final p = s.split('-').map(int.parse).toList();
  return DateTime(p[0], p[1], p[2]);
}

DateTime _monday(DateTime d) => DateTime(d.year, d.month, d.day - (d.weekday - 1));

class Period {
  final Span span;
  final DateTime start, end; // inclusive days
  const Period(this.span, this.start, this.end);

  factory Period.containing(Span span, DateTime anchor) {
    final a = dateOnly(anchor);
    switch (span) {
      case Span.day:
        return Period(span, a, a);
      case Span.week:
        final m = _monday(a);
        return Period(span, m, DateTime(m.year, m.month, m.day + 6));
      case Span.month:
        return Period(span, DateTime(a.year, a.month, 1), DateTime(a.year, a.month + 1, 0));
      case Span.sixMonths:
        final m = _monday(a);
        return Period(span, DateTime(m.year, m.month, m.day - 25 * 7), DateTime(m.year, m.month, m.day + 6));
      case Span.year:
        return Period(span, DateTime(a.year, a.month - 11, 1), DateTime(a.year, a.month + 1, 0));
    }
  }

  Period shift(int dir) {
    switch (span) {
      case Span.day:
        return Period.containing(span, DateTime(start.year, start.month, start.day + dir));
      case Span.week:
        return Period.containing(span, DateTime(start.year, start.month, start.day + 7 * dir));
      case Span.month:
        return Period.containing(span, DateTime(start.year, start.month + dir, 1));
      case Span.sixMonths:
        return Period.containing(span, DateTime(end.year, end.month, end.day + 26 * 7 * dir));
      case Span.year:
        return Period.containing(span, DateTime(end.year, end.month + 12 * dir, 1));
    }
  }

  bool get reachesToday => !end.isBefore(dateOnly(DateTime.now()));

  String get title {
    String dm(DateTime d) => '${d.day} ${_months[d.month - 1]}';
    switch (span) {
      case Span.day:
        return '${_days[start.weekday - 1]} ${dm(start)} ${start.year}';
      case Span.week:
        return start.month == end.month ? '${start.day}–${dm(end)}' : '${dm(start)} – ${dm(end)}';
      case Span.month:
        return '${const ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'][start.month - 1]} ${start.year}';
      case Span.sixMonths:
      case Span.year:
        return '${_months[start.month - 1]} ${start.year} – ${_months[end.month - 1]} ${end.year}';
    }
  }

  /// Groups of days that become one point each.
  List<(String label, List<DateTime> days)> groups() {
    final out = <(String, List<DateTime>)>[];
    switch (span) {
      case Span.day:
      case Span.week:
      case Span.month:
        for (var d = start; !d.isAfter(end); d = DateTime(d.year, d.month, d.day + 1)) {
          out.add((span == Span.week ? _days[d.weekday - 1].substring(0, 1) : '${d.day}', [d]));
        }
      case Span.sixMonths:
        for (var w = start; !w.isAfter(end); w = DateTime(w.year, w.month, w.day + 7)) {
          out.add(('${w.day} ${_months[w.month - 1]}', [for (var i = 0; i < 7; i++) DateTime(w.year, w.month, w.day + i)]));
        }
      case Span.year:
        for (var m = start; !m.isAfter(end); m = DateTime(m.year, m.month + 1, 1)) {
          final last = DateTime(m.year, m.month + 1, 0).day;
          out.add((_months[m.month - 1], [for (var i = 0; i < last; i++) DateTime(m.year, m.month, 1 + i)]));
        }
    }
    return out;
  }
}

double? _mean(Iterable<double?> xs) {
  final v = xs.whereType<double>().toList();
  return v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;
}

/// One chart point per group: averages of the days that have data. No band for future days.
List<ChartPoint> chartPoints(Biometrics data, WearableMetric metric, Period period) {
  final today = dateOnly(DateTime.now());
  return period.groups().map((g) {
    final (label, days) = g;
    final past = days.where((d) => !d.isAfter(today)).toList();
    final rows = past.map((d) => data.dayOf(dayKey(d))).whereType<BiometricDay>().toList();
    final bands = past.map((d) => data.baselineOf(metric.key, dayKey(d))).whereType<BaselinePoint>().toList();
    return ChartPoint(
      label,
      value: _mean(rows.map((r) => r.number(metric.key))),
      low: metric.lowKey == null ? null : _mean(rows.map((r) => r.number(metric.lowKey!))),
      high: metric.highKey == null ? null : _mean(rows.map((r) => r.number(metric.highKey!))),
      bandLo: _mean(bands.map((b) => b.lo)),
      bandHi: _mean(bands.map((b) => b.hi)),
    );
  }).toList();
}
