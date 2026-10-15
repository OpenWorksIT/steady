// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../models.dart';
import '../../wearable/metrics.dart';
import '../patient/history_screen.dart';
import '../theme.dart';
import '../wearable/wearable_views.dart';
import '../widgets.dart';
import 'assign_screen.dart';
import 'clinician_shell.dart';
import 'result_screen.dart';

class _Detail {
  final PatientSummary summary;
  final List<Assignment> assignments;
  final List<Checkin> checkins;
  _Detail(this.summary, this.assignments, this.checkins);
}

class PatientDetailScreen extends StatefulWidget {
  final String patientId, name;
  const PatientDetailScreen({required this.patientId, required this.name, super.key});
  @override
  State<PatientDetailScreen> createState() => _PatientDetailScreenState();
}

class _PatientDetailScreenState extends State<PatientDetailScreen> with SingleTickerProviderStateMixin {
  Key _key = UniqueKey();
  late final TabController _tabs = TabController(length: 2, vsync: this);
  WearableMetric? _openMetric;

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _openWearable(WearableMetric m) {
    setState(() => _openMetric = m);
    _tabs.animateTo(1);
  }

  Future<_Detail> _load() async {
    final api = AppScope.api(context);
    final r = await Future.wait([
      api.patientSummary(widget.patientId),
      api.assignmentsFor(widget.patientId),
      api.checkinsFor(widget.patientId, days: 14),
    ]);
    return _Detail(r[0] as PatientSummary, r[1] as List<Assignment>, r[2] as List<Checkin>);
  }

  void _reload() => setState(() => _key = UniqueKey());

  Future<void> _send() async {
    final sent = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => AssignScreen(patientId: widget.patientId, patientName: widget.name)),
    );
    if (sent == true) _reload();
  }

  Future<void> _deactivate() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Stop ${widget.name}\'s access?'),
        content: const Text('They will be signed out and can\'t sign in again. Waiting activities are cancelled. '
            'Their records stay for the practice\'s files.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Stop access')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final nav = Navigator.of(context);
    await guarded(context, () async {
      await AppScope.api(context).deactivatePatient(widget.patientId);
      nav.pop();
    }, done: 'Access stopped');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name),
        actions: [
          IconButton(tooltip: 'Send something', onPressed: _send, icon: const Icon(Icons.send_outlined)),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'deactivate') _deactivate();
            },
            itemBuilder: (_) => const [PopupMenuItem(value: 'deactivate', child: Text('Stop access'))],
          ),
        ],
        bottom: TabBar(controller: _tabs, tabs: const [Tab(text: 'Overview'), Tab(text: 'Wearable')]),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _overview(),
          WearableTab(patientId: widget.patientId, initialMetric: _openMetric),
        ],
      ),
    );
  }

  Widget _overview() => Loader<_Detail>(
        key: _key,
        load: _load,
        builder: (context, d, reload) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          children: [
            if (d.summary.flags.isNotEmpty) ...[
              Wrap(spacing: 6, runSpacing: 6, children: [for (final f in d.summary.flags) FlagChip(f.label, f.severity)]),
              const SizedBox(height: 12),
            ],
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const SectionHeader('Last 14 days', trailing: 'daily average, 1\u20135'),
                  TrendChart(mood: d.summary.mood, anxiety: d.summary.anxiety),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            WearableWeekCard(patientId: widget.patientId, onOpen: _openWearable),
            const SizedBox(height: 12),
            FilledButton.icon(onPressed: _send, icon: const Icon(Icons.send), label: const Text('Send a questionnaire or exercise')),
            const SizedBox(height: 8),
            const SectionHeader('Questionnaires and exercises'),
            if (d.assignments.isEmpty) Text('Nothing sent yet.', style: TextStyle(color: context.sc.ink2)),
            for (final a in d.assignments)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _AssignmentRow(a, onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ResultScreen(assignmentId: a.id)));
                  reload();
                }),
              ),
            SectionHeader('Check-ins', trailing: '${d.checkins.length} in 14 days'),
            if (d.checkins.isEmpty) Text('No check-ins in the last 14 days.', style: TextStyle(color: context.sc.ink2)),
            for (final c in d.checkins) Padding(padding: const EdgeInsets.only(bottom: 8), child: CheckinCard(c)),
          ],
        ),
      );
}

class _AssignmentRow extends StatelessWidget {
  final Assignment a;
  final VoidCallback onTap;
  const _AssignmentRow(this.a, {required this.onTap});
  @override
  Widget build(BuildContext context) {
    Widget trailing;
    if (a.status == 'pending') {
      trailing = FlagChip(a.available ? 'Waiting' : 'From ${a.availableFrom!.day}/${a.availableFrom!.month}', Severity.none);
    } else if (a.score != null) {
      trailing = FlagChip('${_fmt(a.score!.total)}/${_fmt(a.score!.max)}', a.score!.severity);
    } else {
      trailing = const FlagChip('Done', Severity.none);
    }
    final when = a.status == 'done'
        ? 'Completed ${relTime(a.completedAt)}${a.selfStarted ? ' · self-started' : ''}'
        : 'Sent ${relTime(a.created)}${a.repeat != 'once' && a.repeat.isNotEmpty ? ' · repeats ${a.repeat}' : ''}';
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Glyph(iconFor(a.instrument), calm: !(a.instrument?.isQuestionnaire ?? true)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(a.name, style: context.tt.titleMedium),
                Text(when, style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
              ]),
            ),
            trailing,
          ]),
        ),
      ),
    );
  }
}

String _fmt(num n) => n == n.roundToDouble() ? n.toInt().toString() : n.toStringAsFixed(1);
