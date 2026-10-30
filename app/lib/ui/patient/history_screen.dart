// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../models.dart';
import '../theme.dart';
import '../widgets.dart';

/// The patient's own check-ins over time, as their psychologist sees them: seeing themselves
/// over weeks helps people make sense of how they've been. No flags or research scores here.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  int _days = 14;
  Key _key = UniqueKey();

  /// Daily averages of one rating, oldest first, ending today.
  static List<double?> daily(List<Checkin> list, int days, int Function(Checkin) pick) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final sums = List<double>.filled(days, 0), counts = List<int>.filled(days, 0);
    for (final c in list) {
      final t = c.created.toLocal();
      final ago = today.difference(DateTime(t.year, t.month, t.day)).inDays;
      if (ago < 0 || ago >= days) continue;
      sums[days - 1 - ago] += pick(c);
      counts[days - 1 - ago]++;
    }
    return [for (var i = 0; i < days; i++) counts[i] == 0 ? null : sums[i] / counts[i]];
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Your check-ins')),
        body: Loader<List<Checkin>>(
          key: _key,
          load: () => AppScope.api(context).myCheckins(days: _days),
          builder: (context, list, _) {
            final start = _days == 14 ? '2 weeks ago' : _days == 30 ? 'A month ago' : '3 months ago';
            return ListView(padding: const EdgeInsets.fromLTRB(18, 4, 18, 24), children: [
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 14, label: Text('2 weeks')),
                  ButtonSegment(value: 30, label: Text('Month')),
                  ButtonSegment(value: 91, label: Text('3 months')),
                ],
                selected: {_days},
                onSelectionChanged: (v) => setState(() {
                  _days = v.first;
                  _key = UniqueKey();
                }),
              ),
              const SizedBox(height: 12),
              if (list.isEmpty)
                Text('No check-ins in this time yet.', style: TextStyle(color: context.sc.ink2))
              else ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: TrendChart(
                      mood: daily(list, _days, (c) => c.mood),
                      anxiety: daily(list, _days, (c) => c.anxiety),
                      startLabel: start,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: TrendChart(
                      mood: daily(list, _days, (c) => c.sleep),
                      anxiety: daily(list, _days, (c) => c.energy),
                      firstLabel: 'Sleep',
                      secondLabel: 'Energy',
                      startLabel: start,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text('Each point is a day\'s average, 1 to 5.', style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
                const SizedBox(height: 12),
                for (final c in list) Padding(padding: const EdgeInsets.only(bottom: 8), child: CheckinCard(c)),
              ],
            ]);
          },
        ),
      );
}

class CheckinCard extends StatelessWidget {
  final Checkin c;
  const CheckinCard(this.c, {super.key});
  @override
  Widget build(BuildContext context) {
    Widget score(String l, int v) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: context.cs.surface,
            border: Border.all(color: context.sc.line),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text('$l $v', style: context.tt.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(relTime(c.created), style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            score('Mood', c.mood),
            score('Anxiety', c.anxiety),
            score('Sleep', c.sleep),
            score('Energy', c.energy),
          ]),
          if (c.note.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('“${c.note}”', style: context.tt.bodyMedium?.copyWith(fontStyle: FontStyle.italic)),
          ],
        ]),
      ),
    );
  }
}
