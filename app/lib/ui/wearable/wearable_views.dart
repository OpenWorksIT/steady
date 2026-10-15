// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Clinician views of a patient's watch data: a 7-day summary on the patient's overview,
// and a Wearable tab to explore by day, week, month, 6 months or year. The shaded band is
// the patient's own usual range (10th-90th percentile of the previous 28 days). Display only.
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../models.dart';
import '../../services/api.dart';
import '../../wearable/metrics.dart';
import '../../wearable/summary.dart';
import '../theme.dart';
import '../widgets.dart';
import 'periods.dart';
import 'wearable_chart.dart';

String _rangeText(WearableMetric m, BaselinePoint? b) =>
    (b == null || b.lo == null || b.hi == null) ? '' : 'usual ${m.format(b.lo!)}–${m.format(b.hi!)}';

/// Small 7-day view for the patient overview. Tapping a row opens the Wearable tab on it.
class WearableWeekCard extends StatelessWidget {
  final String patientId;
  final ValueChanged<WearableMetric> onOpen;
  const WearableWeekCard({required this.patientId, required this.onOpen, super.key});

  @override
  Widget build(BuildContext context) {
    final today = dateOnly(DateTime.now());
    final period = Period(Span.week, today.subtract(const Duration(days: 6)), today);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Loader<Biometrics>(
          load: () => AppScope.api(context).patientBiometrics(patientId, from: dayKey(period.start), to: dayKey(period.end)),
          builder: (context, data, _) {
            final shown = wearableMetrics.where((m) => data.days.any((d) => d.number(m.key) != null)).toList();
            return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              SectionHeader('Watch · last 7 days', trailing: data.connected ? 'shaded = usual range' : 'not connected'),
              if (shown.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    data.connected
                        ? 'Connected, but no watch data in the last 7 days.'
                        : 'No watch data. The patient can connect their watch from their Steady home screen.',
                    style: TextStyle(color: context.sc.ink2),
                  ),
                ),
              for (final m in shown) _MiniRow(metric: m, data: data, period: period, onTap: () => onOpen(m)),
            ]);
          },
        ),
      ),
    );
  }
}

class _MiniRow extends StatelessWidget {
  final WearableMetric metric;
  final Biometrics data;
  final Period period;
  final VoidCallback onTap;
  const _MiniRow({required this.metric, required this.data, required this.period, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final points = chartPoints(data, metric, period);
    BiometricDay? latest;
    for (final d in data.days.reversed) {
      if (d.number(metric.key) != null) {
        latest = d;
        break;
      }
    }
    final v = latest?.number(metric.key);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          SizedBox(
            width: 112,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(metric.short, style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
              Text(v == null ? '–' : metric.format(v), style: context.tt.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            ]),
          ),
          Expanded(child: WearableChart(points: points, metric: metric, height: 34, compact: true)),
          Icon(Icons.chevron_right, size: 18, color: context.sc.ink3),
        ]),
      ),
    );
  }
}

/// The Wearable tab.
class WearableTab extends StatefulWidget {
  final String patientId;
  final WearableMetric? initialMetric;
  const WearableTab({required this.patientId, this.initialMetric, super.key});
  @override
  State<WearableTab> createState() => _WearableTabState();
}

class _WearableTabState extends State<WearableTab> with AutomaticKeepAliveClientMixin {
  late WearableMetric _metric = widget.initialMetric ?? wearableMetrics.first;
  Period _period = Period.containing(Span.week, DateTime.now());
  int? _selected;
  Future<Biometrics>? _future;

  @override
  bool get wantKeepAlive => true;

  @override
  void didUpdateWidget(WearableTab old) {
    super.didUpdateWidget(old);
    if (widget.initialMetric != null && widget.initialMetric != old.initialMetric) {
      setState(() => _metric = widget.initialMetric!);
    }
  }

  Future<Biometrics> _load() {
    final today = dateOnly(DateTime.now());
    final end = _period.end.isAfter(today) ? today : _period.end;
    return AppScope.api(context).patientBiometrics(widget.patientId, from: dayKey(_period.start), to: dayKey(end));
  }

  void _setPeriod(Period p) => setState(() {
        _period = p;
        _selected = null;
        _future = _load();
      });

  void _zoomInto(int index) {
    final groups = _period.groups();
    if (index >= groups.length) return;
    final first = groups[index].$2.first;
    if (first.isAfter(dateOnly(DateTime.now()))) return;
    switch (_period.span) {
      case Span.week:
      case Span.month:
        _setPeriod(Period.containing(Span.day, first));
      case Span.sixMonths:
        _setPeriod(Period.containing(Span.week, first));
      case Span.year:
        _setPeriod(Period.containing(Span.month, first));
      case Span.day:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    _future ??= _load();
    return RefreshIndicator(
      onRefresh: () async {
        setState(() => _future = _load());
        await _future;
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<Span>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: Span.day, label: Text('Day')),
                ButtonSegment(value: Span.week, label: Text('Week')),
                ButtonSegment(value: Span.month, label: Text('Month')),
                ButtonSegment(value: Span.sixMonths, label: Text('6 mo')),
                ButtonSegment(value: Span.year, label: Text('Year')),
              ],
              selected: {_period.span},
              onSelectionChanged: (s) {
                final anchor = _period.end.isAfter(dateOnly(DateTime.now())) ? DateTime.now() : _period.end;
                _setPeriod(Period.containing(s.first, anchor));
              },
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            IconButton(tooltip: 'Earlier', onPressed: () => _setPeriod(_period.shift(-1)), icon: const Icon(Icons.chevron_left)),
            Expanded(child: Text(_period.title, textAlign: TextAlign.center, style: context.tt.titleMedium)),
            IconButton(
              tooltip: 'Later',
              onPressed: _period.reachesToday ? null : () => _setPeriod(_period.shift(1)),
              icon: const Icon(Icons.chevron_right),
            ),
          ]),
          if (_period.span != Span.day) ...[
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final m in wearableMetrics)
                ChoiceChip(
                  label: Text(m.short),
                  selected: m == _metric,
                  onSelected: (_) => setState(() {
                    _metric = m;
                    _selected = null;
                  }),
                ),
            ]),
            const SizedBox(height: 12),
          ],
          FutureBuilder<Biometrics>(
            future: _future,
            builder: (context, snap) {
              if (snap.hasError) {
                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(errorText(snap.error!), textAlign: TextAlign.center),
                );
              }
              if (!snap.hasData) {
                return const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()));
              }
              final data = snap.data!;
              return _period.span == Span.day ? _DayDetail(data: data, day: _period.start) : _periodView(context, data);
            },
          ),
        ],
      ),
    );
  }

  Widget _periodView(BuildContext context, Biometrics data) {
    final points = chartPoints(data, _metric, _period);
    final withData = points.where((p) => p.hasValue).toList();
    final vals = points.map((p) => p.value).whereType<double>().toList();
    final avg = vals.isEmpty ? null : vals.reduce((a, b) => a + b) / vals.length;
    final latestBase = (data.baseline[_metric.key] ?? const <BaselinePoint>[]).lastOrNull;
    final sel = _selected != null && _selected! < points.length ? points[_selected!] : null;
    final unit = switch (_period.span) { Span.sixMonths => 'week', Span.year => 'month', _ => 'day' };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 14, 14, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Text(
                sel != null
                    ? '${sel.label}: ${sel.value == null ? 'no data' : _metric.format(sel.value!)}'
                        '${sel.low != null && sel.high != null ? '  (${_metric.format(sel.low!)}–${_metric.format(sel.high!)})' : ''}'
                    : avg == null
                        ? _metric.label
                        : '${_metric.label} · average ${_metric.format(avg)}',
                style: context.tt.titleSmall,
              ),
            ),
            WearableChart(
              points: points,
              metric: _metric,
              height: 220,
              selected: _selected,
              onTap: (i) => setState(() => _selected = _selected == i ? null : i),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 10),
      if (withData.isEmpty)
        Text('No ${_metric.label.toLowerCase()} data for this period.', style: TextStyle(color: context.sc.ink2))
      else ...[
        Text(
          latestBase?.lo != null
              ? 'Shaded band: usual range from the previous 28 days. Latest: ${_metric.format(latestBase!.lo!)}–${_metric.format(latestBase.hi!)}.'
              : 'The usual range appears once ${data.baselineMin} days of data exist (${latestBase?.n ?? 0} so far).',
          style: context.tt.bodySmall?.copyWith(color: context.sc.ink2),
        ),
        const SizedBox(height: 4),
        Text('${withData.length} ${unit}s with data. Tap a $unit to select it.', style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
        if (_selected != null && _period.span != Span.day) ...[
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => _zoomInto(_selected!),
            child: Text(switch (_period.span) {
              Span.sixMonths => 'Open this week',
              Span.year => 'Open this month',
              _ => 'Open this day',
            }),
          ),
        ],
      ],
      if (_metric.key == 'rhr') ...[
        const SizedBox(height: 12),
        Text(
          'Resting heart rate is calculated by Steady the same way for every watch: the lowest 30-minute average during '
          'that night\'s sleep, or during the day if no sleep was recorded.',
          style: context.tt.bodySmall?.copyWith(color: context.sc.ink3),
        ),
      ],
    ]);
  }
}


/// Everything recorded for one day, each with the patient's usual range.
class _DayDetail extends StatelessWidget {
  final Biometrics data;
  final DateTime day;
  const _DayDetail({required this.data, required this.day});

  @override
  Widget build(BuildContext context) {
    final key = dayKey(day);
    final d = data.dayOf(key);
    if (d == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text('No watch data for this day.', style: TextStyle(color: context.sc.ink2)),
      );
    }
    Widget row(String label, String value, {String sub = ''}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Text(label, style: TextStyle(color: context.sc.ink2))),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(value, style: const TextStyle(fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
              if (sub.isNotEmpty) Text(sub, style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
            ]),
          ]),
        );
    String? f(String k, String Function(double) fmt) => d.number(k) == null ? null : fmt(d.number(k)!);
    String usual(String metricKey) {
      final m = wearableMetrics.where((x) => x.key == metricKey).firstOrNull;
      return m == null ? '' : _rangeText(m, data.baselineOf(metricKey, key));
    }

    final rows = <Widget>[
      if (f('rhr', (v) => '${v.round()} bpm') case final v?)
        row('Resting heart rate', v, sub: [usual('rhr'), if (d.text('rhr_method') == 'awake') 'measured awake'].where((s) => s.isNotEmpty).join(' · ')),
      if (f('hr_avg', (v) => '${v.round()} bpm') case final v?) row('Average heart rate', v, sub: usual('hr_avg')),
      if (d.number('hr_min') != null && d.number('hr_max') != null)
        row('Heart rate range', '${d.number('hr_min')!.round()}–${d.number('hr_max')!.round()} bpm',
            sub: d.number('hr_samples') != null ? '${d.number('hr_samples')!.round()} readings' : ''),
      if (f('sleep_min', formatMinutes) case final v?) row('Sleep', v, sub: usual('sleep_min')),
      if (d.number('sleep_onset') != null && d.number('sleep_wake') != null)
        row('Asleep → awake', '${formatClock(d.number('sleep_onset')!)} → ${formatClock(d.number('sleep_wake')!)}', sub: usual('sleep_onset')),
      if (['sleep_deep', 'sleep_light', 'sleep_rem', 'sleep_awake'].any((k) => d.number(k) != null))
        row(
          'Sleep stages',
          [
            if (f('sleep_deep', formatMinutes) case final v?) 'deep $v',
            if (f('sleep_light', formatMinutes) case final v?) 'light $v',
            if (f('sleep_rem', formatMinutes) case final v?) 'REM $v',
          ].join(' · '),
          sub: f('sleep_awake', formatMinutes) == null ? '' : 'awake ${f('sleep_awake', formatMinutes)}',
        ),
      if (f('steps', formatSteps) case final v?) row('Steps', v, sub: usual('steps')),
      if (f('spo2_avg', (v) => '${v.toStringAsFixed(1)}%') case final v?)
        row('Blood oxygen', v, sub: [usual('spo2_avg'), if (d.number('spo2_min') != null) 'lowest ${d.number('spo2_min')!.toStringAsFixed(0)}%'].where((s) => s.isNotEmpty).join(' · ')),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
        child: Column(children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(height: 1, color: context.sc.line),
            rows[i],
          ],
        ]),
      ),
    );
  }
}
