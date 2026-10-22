// SPDX-License-Identifier: AGPL-3.0-or-later
//
// RADR, the Research Amon Dîn Rating: a research view of how far a patient's watch data and
// check-ins are from their own normal, by domain, and whether the two move together. It is not
// a risk score, prediction or diagnosis. The server works it out (server/pb_hooks/lib/radr.js);
// docs/RADR.md explains the method and the research behind it.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../models.dart' show Severity, asList, asMap;
import '../theme.dart';
import '../widgets.dart';

const _domains = ['sleep', 'circadian', 'activity', 'cardiac'];
const _domainNames = {'sleep': 'Sleep', 'circadian': 'Body clock', 'activity': 'Activity', 'cardiac': 'Heart'};
const _domainWhat = {
  'sleep': 'Duration away from usual, and night-to-night variability of falling asleep and waking',
  'circadian': 'The middle of the night\'s sleep moving earlier or later',
  'activity': 'Fewer steps than usual',
  'cardiac': 'Resting heart rate above usual (and heart rate variability below, if the watch gives it)',
};

double? _d(Object? v) => v is num ? v.toDouble() : null;

class RadrTab extends StatefulWidget {
  final String patientId;
  const RadrTab({required this.patientId, super.key});
  @override
  State<RadrTab> createState() => _RadrTabState();
}

class _RadrTabState extends State<RadrTab> with AutomaticKeepAliveClientMixin {
  int _days = 56;
  Key _key = UniqueKey();

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final api = AppScope.api(context);
    return Loader<Map<String, dynamic>>(
      key: _key,
      load: () => api.radr(widget.patientId, days: _days),
      builder: (context, r, reload) {
        final days = asList(r['days']).map(asMap).toList();
        final rated = days.where((d) => d['watch'] != null).toList();
        final latest = asMap(r['latest']);
        return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 28), children: [
          _ResearchBanner(demo: r['demo'] == true),
          const SizedBox(height: 10),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 28, label: Text('4 weeks')),
              ButtonSegment(value: 56, label: Text('8 weeks')),
              ButtonSegment(value: 91, label: Text('3 months')),
            ],
            selected: {_days},
            onSelectionChanged: (v) => setState(() {
              _days = v.first;
              _key = UniqueKey();
            }),
          ),
          const SizedBox(height: 12),
          if (rated.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  r['watchConnected'] == true
                      ? 'Not enough watch data yet. RADR compares each day with the person\'s own previous four weeks, '
                          'so it starts once there are about three weeks of nights to compare with.'
                      : 'This patient hasn\'t connected a watch. RADR needs watch data.',
                  style: TextStyle(color: context.sc.ink2),
                ),
              ),
            )
          else ...[
            _Latest(latest),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const SectionHeader('Over time', trailing: '0 = usual for them, 4 = far from usual'),
                  SizedBox(height: 190, child: _RadrChart(days: days, questionnaires: asList(r['questionnaires']).map(asMap).toList())),
                  const SizedBox(height: 6),
                  Wrap(spacing: 14, runSpacing: 4, children: [
                    _Key(color: context.cs.primary, label: 'Watch index'),
                    _Key(color: context.sc.warn, label: 'Check-ins', dashed: true),
                    _Key(color: context.sc.alert, label: 'PHQ-9 (right axis)', dot: true),
                    _Key(color: context.sc.alertSoft, label: '2+ domains at once', block: true),
                  ]),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const SectionHeader('By domain'),
                  Text('Each square is a day. Darker means further from this person\'s own normal.',
                      style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
                  const SizedBox(height: 8),
                  _Heatmap(days: days),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            _Concordance(asList(r['concordance']).map(asMap).toList()),
          ],
          const SizedBox(height: 12),
          _Coverage(r),
          const SizedBox(height: 4),
          const _Method(),
        ]);
      },
    );
  }
}

class _ResearchBanner extends StatelessWidget {
  final bool demo;
  const _ResearchBanner({required this.demo});
  @override
  Widget build(BuildContext context) => Card(
        color: context.sc.accentSoft,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.science_outlined, color: context.cs.primary),
              const SizedBox(width: 8),
              Expanded(child: Text('RADR · Research Amon Dîn Rating', style: context.tt.titleMedium)),
            ]),
            const SizedBox(height: 6),
            Text(
              'For research only. Not a risk score, prediction or diagnosis, and not checked around the clock. '
              'It shows how far this person\'s watch data and check-ins are from their own normal, to study how '
              'Amon Dîn should work.',
              style: context.tt.bodySmall,
            ),
            if (demo) ...[
              const SizedBox(height: 8),
              const FlagChip('Fictional demo patient: made-up data', Severity.warn),
            ],
          ]),
        ),
      );
}

class _Latest extends StatelessWidget {
  final Map<String, dynamic> d;
  const _Latest(this.d);
  @override
  Widget build(BuildContext context) {
    final dom = asMap(d['domains']);
    final conv = (d['convergent'] as num?)?.toInt() ?? 0;
    final watch = _d(d['watch']);
    final self = _d(d['self']);
    final combined = _d(d['combined']);
    String f(double? v) => v == null ? '-' : v.toStringAsFixed(1);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SectionHeader('Latest', trailing: '${d['day'] ?? ''}'),
          Row(children: [
            _Big(label: 'Watch index', value: f(watch)),
            _Big(label: 'Domains away from usual', value: '$conv of 4'),
            _Big(label: 'Check-ins', value: f(self)),
            _Big(label: 'Combined', value: f(combined)),
          ]),
          const SizedBox(height: 12),
          for (final k in _domains) _DomainBar(name: _domainNames[k]!, what: _domainWhat[k]!, value: _d(dom[k]),
              extra: k == 'circadian' && d['shift'] != null && (_d(dom[k]) ?? 0) >= 1 ? 'sleeping ${d['shift']} than usual' : null),
        ]),
      ),
    );
  }
}

class _Big extends StatelessWidget {
  final String label, value;
  const _Big({required this.label, required this.value});
  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: context.tt.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
          Text(label, style: context.tt.bodySmall?.copyWith(color: context.sc.ink2), maxLines: 2),
        ]),
      );
}

class _DomainBar extends StatelessWidget {
  final String name, what;
  final double? value;
  final String? extra;
  const _DomainBar({required this.name, required this.what, required this.value, this.extra});
  @override
  Widget build(BuildContext context) {
    final v = (value ?? 0).clamp(0, 4) / 4;
    final strong = (value ?? 0) >= 1.5;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(name, style: context.tt.titleSmall)),
          Text(value == null ? 'no data' : value!.toStringAsFixed(1),
              style: TextStyle(color: strong ? context.sc.alert : context.sc.ink2, fontWeight: strong ? FontWeight.w700 : null)),
        ]),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: v.toDouble(),
            minHeight: 8,
            backgroundColor: context.sc.line,
            color: strong ? context.sc.alert : context.cs.primary,
          ),
        ),
        const SizedBox(height: 2),
        Text(extra == null ? what : '$what · $extra', style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
      ]),
    );
  }
}

class _Key extends StatelessWidget {
  final Color color;
  final String label;
  final bool dashed, dot, block;
  const _Key({required this.color, required this.label, this.dashed = false, this.dot = false, this.block = false});
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: block ? 14 : (dot ? 8 : 16),
          height: block ? 10 : (dot ? 8 : 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: dashed ? 0.6 : 1),
            shape: dot ? BoxShape.circle : BoxShape.rectangle,
          ),
        ),
        const SizedBox(width: 5),
        Text(label, style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
      ]);
}

/// Watch index and check-in score over the days (0..4, left), PHQ-9 totals as dots (0..27, right),
/// and a band where two or more domains were away from usual together.
class _RadrChart extends StatelessWidget {
  final List<Map<String, dynamic>> days;
  final List<Map<String, dynamic>> questionnaires;
  const _RadrChart({required this.days, required this.questionnaires});
  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.infinite,
        painter: _ChartPainter(
          days: days,
          phq: questionnaires.where((q) => q['key'] == 'phq9').toList(),
          line: context.cs.primary,
          self: context.sc.warn,
          dot: context.sc.alert,
          band: context.sc.alertSoft,
          grid: context.sc.line,
          text: context.sc.ink3,
        ),
      );
}

class _ChartPainter extends CustomPainter {
  final List<Map<String, dynamic>> days, phq;
  final Color line, self, dot, band, grid, text;
  _ChartPainter({required this.days, required this.phq, required this.line, required this.self, required this.dot, required this.band, required this.grid, required this.text});

  @override
  void paint(Canvas canvas, Size size) {
    if (days.isEmpty) return;
    const left = 22.0, right = 26.0, top = 6.0, bottom = 18.0;
    final w = size.width - left - right, h = size.height - top - bottom;
    double x(int i) => left + (days.length == 1 ? w / 2 : w * i / (days.length - 1));
    double y(double v) => top + h * (1 - v.clamp(0, 4) / 4);
    final style = TextStyle(color: text, fontSize: 9);
    void label(String s, Offset at, {bool rightAlign = false}) {
      final tp = TextPainter(text: TextSpan(text: s, style: style), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, at - Offset(rightAlign ? 0 : tp.width, tp.height / 2));
    }

    // bands where 2+ domains were away from usual together
    final bandPaint = Paint()..color = band;
    final step = days.length > 1 ? w / (days.length - 1) : w;
    for (var i = 0; i < days.length; i++) {
      if (((days[i]['convergent'] as num?) ?? 0) >= 2) {
        canvas.drawRect(Rect.fromLTWH(x(i) - step / 2, top, step, h), bandPaint);
      }
    }
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final v in [0, 1, 2, 3, 4]) {
      canvas.drawLine(Offset(left, y(v.toDouble())), Offset(left + w, y(v.toDouble())), gridPaint);
      label('$v', Offset(left - 4, y(v.toDouble())));
    }
    for (final v in [0, 9, 18, 27]) {
      label('$v', Offset(left + w + 4, top + h * (1 - v / 27)), rightAlign: true);
    }
    // a few dates along the bottom
    final every = math.max(1, (days.length / 5).ceil());
    for (var i = 0; i < days.length; i += every) {
      final d = '${days[i]['day'] ?? ''}';
      if (d.length == 10) label('${int.parse(d.substring(8))}/${int.parse(d.substring(5, 7))}', Offset(x(i) + 10, top + h + 10));
    }

    void series(String key, Color c, {bool dashed = false, double width = 2.4}) {
      final p = Paint()
        ..color = c
        ..strokeWidth = width
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      Offset? prev;
      for (var i = 0; i < days.length; i++) {
        final v = _d(days[i][key]);
        if (v == null) {
          prev = null;
          continue;
        }
        final pt = Offset(x(i), y(v));
        if (prev != null) {
          if (dashed) {
            final dist = (pt - prev).distance;
            final dir = (pt - prev) / dist;
            for (var s = 0.0; s < dist; s += 7) {
              canvas.drawLine(prev + dir * s, prev + dir * math.min(s + 4, dist), p);
            }
          } else {
            canvas.drawLine(prev, pt, p);
          }
        }
        prev = pt;
      }
    }

    series('self', self.withValues(alpha: 0.85), dashed: true, width: 1.8);
    series('watch', line);

    // PHQ-9 totals on the right axis
    final index = {for (var i = 0; i < days.length; i++) '${days[i]['day']}': i};
    final dotPaint = Paint()..color = dot;
    for (final q in phq) {
      final i = index['${q['day']}'];
      final t = _d(q['total']);
      if (i == null || t == null) continue;
      canvas.drawCircle(Offset(x(i), top + h * (1 - t.clamp(0, 27) / 27)), 3.5, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) => old.days != days || old.phq != phq;
}

/// Four rows (domains) by days, shaded by distance from usual.
class _Heatmap extends StatelessWidget {
  final List<Map<String, dynamic>> days;
  const _Heatmap({required this.days});
  @override
  Widget build(BuildContext context) {
    final base = context.cs.primary;
    final hot = context.sc.alert;
    return LayoutBuilder(builder: (context, c) {
      const labelW = 74.0;
      final cell = math.max(2.0, (c.maxWidth - labelW) / math.max(1, days.length));
      return Column(children: [
        for (final k in _domains)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(children: [
              SizedBox(width: labelW, child: Text(_domainNames[k]!, style: context.tt.bodySmall)),
              for (final d in days)
                Builder(builder: (context) {
                  final v = _d(asMap(d['domains'])[k]);
                  final color = v == null
                      ? context.sc.line.withValues(alpha: 0.4)
                      : v >= 1.5
                          ? Color.lerp(hot.withValues(alpha: 0.45), hot, ((v - 1.5) / 2.5).clamp(0, 1))!
                          : base.withValues(alpha: 0.08 + 0.3 * (v / 1.5));
                  return Tooltip(
                    message: '${d['day']}: ${v == null ? 'no data' : v.toStringAsFixed(1)}',
                    child: Container(width: cell - 1, height: 14, margin: const EdgeInsets.only(right: 1), color: color),
                  );
                }),
            ]),
          ),
      ]);
    });
  }
}

class _Concordance extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  const _Concordance(this.rows);
  @override
  Widget build(BuildContext context) {
    String rho(Object? v) => v is num ? v.toStringAsFixed(2) : 'too few days';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SectionHeader('Does the watch agree with the check-ins?'),
          Text(
            'Rank correlation between the watch index and the check-in score, with the watch a few days ahead. '
            'Near 1: they rise together. Near 0: no relation. A stronger value 1 to 3 days ahead would mean the watch '
            'moved before the person reported feeling worse, which is the question Amon Dîn needs answered.',
            style: context.tt.bodySmall?.copyWith(color: context.sc.ink2),
          ),
          const SizedBox(height: 8),
          Table(
            columnWidths: const {0: FlexColumnWidth(2), 1: FlexColumnWidth(1.2), 2: FlexColumnWidth(1)},
            children: [
              TableRow(children: [
                Text('Watch ahead by', style: context.tt.labelMedium),
                Text('Correlation', style: context.tt.labelMedium),
                Text('Days', style: context.tt.labelMedium),
              ]),
              for (final r in rows)
                TableRow(children: [
                  Padding(padding: const EdgeInsets.only(top: 4), child: Text(r['lag'] == 0 ? 'Same day' : '${r['lag']} day${r['lag'] == 1 ? '' : 's'}')),
                  Padding(padding: const EdgeInsets.only(top: 4), child: Text(rho(r['rho']))),
                  Padding(padding: const EdgeInsets.only(top: 4), child: Text('${r['n'] ?? 0}')),
                ]),
            ],
          ),
        ]),
      ),
    );
  }
}

class _Coverage extends StatelessWidget {
  final Map<String, dynamic> r;
  const _Coverage(this.r);
  @override
  Widget build(BuildContext context) {
    final days = asList(r['days']).length;
    return Text(
      'Watch data on ${r['wearDays'] ?? 0} of $days days, check-ins on ${r['checkinDays'] ?? 0}. '
      'Fewer days make every number here less reliable.',
      style: context.tt.bodySmall?.copyWith(color: context.sc.ink3),
    );
  }
}

class _Method extends StatelessWidget {
  const _Method();
  @override
  Widget build(BuildContext context) => ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text('How RADR is worked out', style: context.tt.titleSmall),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '1. Each measure is averaged over 3 days and compared with the person\'s own previous 4 weeks, '
            'leaving out the most recent week so a change that is building up doesn\'t hide in its own baseline.\n'
            '2. Distance from usual is a robust z-score (median and spread), counted only in the direction the '
            'research links to decline, and capped at 4.\n'
            '3. Measures are grouped into sleep, body clock, activity and heart. The watch index is the average of '
            'the domains; "domains away from usual" counts those at 1.5 or more on the same day. Studies report that '
            'single measures predict poorly and that change across several domains together, and alongside what '
            'the person reports, is what carries signal.\n'
            '4. Check-ins (lower mood and energy, more anxiety, worse sleep) are scored the same way and shown '
            'beside the watch, not mixed into it, so the practice can see whether watch data adds anything.\n\n'
            'Sources and limitations: docs/RADR.md in the Steady repository.',
            style: context.tt.bodySmall?.copyWith(color: context.sc.ink2, height: 1.4),
          ),
        ],
      );
}
