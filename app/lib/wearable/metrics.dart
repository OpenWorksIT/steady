// SPDX-License-Identifier: AGPL-3.0-or-later
// How each watch metric is shown to the clinician.

enum ChartKind { bar, line, range }

class WearableMetric {
  final String key; // the value key; for range charts, the middle value
  final String label;
  final String short;
  final ChartKind kind;
  final String? lowKey, highKey; // range charts
  final String Function(double) format;
  final String Function(double) axis;
  const WearableMetric({
    required this.key,
    required this.label,
    required this.short,
    required this.kind,
    required this.format,
    required this.axis,
    this.lowKey,
    this.highKey,
  });
}

String _bpm(double v) => '${v.round()} bpm';
String _int(double v) => '${v.round()}';

String formatMinutes(double m) {
  final total = m.round();
  final h = total ~/ 60, min = total % 60;
  if (h == 0) return '${min}m';
  return min == 0 ? '${h}h' : '${h}h ${min.toString().padLeft(2, '0')}m';
}

String formatSteps(double v) {
  final s = v.round().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// Minutes from the day's midnight (negative = the evening before) as a clock time.
String formatClock(double minutes) {
  var m = minutes.round() % 1440;
  if (m < 0) m += 1440;
  return '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
}

const wearableMetrics = <WearableMetric>[
  WearableMetric(key: 'rhr', label: 'Resting heart rate', short: 'Resting HR', kind: ChartKind.line, format: _bpm, axis: _int),
  WearableMetric(
    key: 'hr_avg',
    label: 'Heart rate',
    short: 'Heart rate',
    kind: ChartKind.range,
    lowKey: 'hr_min',
    highKey: 'hr_max',
    format: _bpm,
    axis: _int,
  ),
  WearableMetric(key: 'sleep_min', label: 'Sleep', short: 'Sleep', kind: ChartKind.bar, format: formatMinutes, axis: _hours),
  WearableMetric(key: 'steps', label: 'Steps', short: 'Steps', kind: ChartKind.bar, format: formatSteps, axis: _thousands),
  WearableMetric(key: 'spo2_avg', label: 'Blood oxygen', short: 'SpO₂', kind: ChartKind.line, format: _pct, axis: _int),
  WearableMetric(key: 'sleep_onset', label: 'Fell asleep', short: 'Bedtime', kind: ChartKind.line, format: formatClock, axis: _clockAxis),
];

String _hours(double m) => '${(m / 60).round()}h';
String _thousands(double v) => v >= 1000 ? '${(v / 1000).toStringAsFixed(v >= 10000 ? 0 : 1)}k' : '${v.round()}';
String _pct(double v) => '${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1)}%';
String _clockAxis(double m) => formatClock(m).substring(0, 2);
