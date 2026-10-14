// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../models.dart';
import '../theme.dart';
import '../widgets.dart';
import 'clinician_shell.dart';

class ResultScreen extends StatelessWidget {
  final String assignmentId;
  const ResultScreen({required this.assignmentId, super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Result')),
      body: Loader<Assignment>(
        load: () => AppScope.api(context).assignment(assignmentId),
        builder: (context, a, reload) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
          children: [
            Text(a.name, style: context.tt.headlineSmall),
            Text(
              a.status == 'done'
                  ? 'Completed ${relTime(a.completedAt)}${a.selfStarted ? ' · self-started' : ''}'
                  : a.status == 'cancelled'
                      ? 'Cancelled'
                      : 'Waiting since ${relTime(a.created)}',
              style: TextStyle(color: context.sc.ink2),
            ),
            if (a.note.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('Your note: “${a.note}”', style: const TextStyle(fontStyle: FontStyle.italic)),
            ],
            const SizedBox(height: 14),
            ..._body(context, a),
            if (a.status == 'pending') ...[
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () => guarded(context, () async {
                  final nav = Navigator.of(context);
                  await AppScope.api(context).cancelAssignment(a.id);
                  nav.pop();
                }, done: 'Cancelled'),
                child: const Text('Cancel this'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _body(BuildContext context, Assignment a) {
    final inst = a.instrument;
    if (a.status != 'done' || inst == null) return const [];
    if (inst.isQuestionnaire) {
      final s = a.score;
      final answers = asMap(a.result['answers']);
      final items = inst.items;
      return [
        if (s != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Total', style: context.tt.labelMedium?.copyWith(color: context.sc.ink3)),
                Text('${_fmt(s.total)} / ${_fmt(s.max)}', style: context.tt.headlineMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  if (s.band.isNotEmpty) FlagChip(s.band, s.flags.isEmpty ? s.severity : Severity.none),
                  for (final f in s.flags) FlagChip(f.label, f.severity),
                ]),
                if (s.subscales.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  for (final sub in s.subscales)
                    Text('${sub.label}: ${_fmt(sub.total)}${sub.max != null ? ' / ${_fmt(sub.max!)}' : ''}',
                        style: context.tt.bodyMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                ],
                if (s.note.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(s.note, style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
                ],
              ]),
            ),
          ),
        const SizedBox(height: 12),
        for (var i = 0; i < items.length; i++)
          if (answers.containsKey(items[i].id))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Item ${i + 1}', style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
                    Text(items[i].text),
                    const SizedBox(height: 4),
                    Row(children: [
                      Expanded(child: Text(_label(items[i], answers[items[i].id]), style: TextStyle(color: context.sc.ink2))),
                      if (items[i].type != 'text') Text('${answers[items[i].id]}', style: const TextStyle(fontWeight: FontWeight.w700)),
                    ]),
                  ]),
                ),
              ),
            ),
        Text('${inst.fullName.isEmpty ? inst.name : inst.fullName} · ${inst.licenceName}. Scores support clinical judgement and are not a diagnosis.',
            style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
      ];
    }
    final ex = inst.exercise;
    if (ex?.type == 'breathing') {
      final secs = (a.result['seconds'] as num?)?.toInt() ?? 0;
      return [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text('${a.result['rounds'] ?? 0} of ${ex!.rounds} rounds · ${secs ~/ 60}m ${secs % 60}s',
                style: context.tt.titleLarge),
          ),
        ),
      ];
    }
    final written = asList(a.result['answers']);
    return [
      for (var i = 0; i < (ex?.steps.length ?? 0); i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(ex!.steps[i].title, style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
                const SizedBox(height: 2),
                Text(i < written.length && '${written[i]}'.isNotEmpty ? '“${written[i]}”' : 'No written answer',
                    style: TextStyle(fontStyle: i < written.length && '${written[i]}'.isNotEmpty ? FontStyle.italic : FontStyle.normal)),
              ]),
            ),
          ),
        ),
    ];
  }

  String _label(Item it, Object? v) {
    if (it.type == 'text') return '“$v”';
    if (it.type == 'number') return '';
    for (final o in it.options) {
      if (o.value == v) return o.label;
    }
    return '';
  }
}

String _fmt(num n) => n == n.roundToDouble() ? n.toInt().toString() : n.toStringAsFixed(1);
