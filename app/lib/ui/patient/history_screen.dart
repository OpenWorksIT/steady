// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../models.dart';
import '../theme.dart';
import '../widgets.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Your check-ins')),
        body: Loader<List<Checkin>>(
          load: () => AppScope.api(context).myCheckins(days: 30),
          builder: (context, list, _) => list.isEmpty
              ? ListView(padding: const EdgeInsets.all(24), children: const [Text('No check-ins in the last 30 days.')])
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) => CheckinCard(list[i]),
                ),
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
