// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../export/export_actions.dart';
import '../../models.dart';
import '../../services/api.dart';
import '../../wearable/metrics.dart';
import '../patient/history_screen.dart';
import '../theme.dart';
import '../wearable/wearable_views.dart';
import '../widgets.dart';
import 'assign_screen.dart';
import 'clinician_shell.dart';
import 'patient_care.dart';
import 'radr_tab.dart';
import 'result_screen.dart';

class _Detail {
  final PatientSummary summary;
  final List<Assignment> assignments;
  final List<Checkin> checkins;
  _Detail(this.summary, this.assignments, this.checkins);
}

class PatientDetailScreen extends StatefulWidget {
  final String patientId, name;

  /// A colleague's patient shared with this psychologist: read only, [owner] is the colleague.
  final bool shared;
  final String owner;
  const PatientDetailScreen({required this.patientId, required this.name, this.shared = false, this.owner = '', super.key});
  @override
  State<PatientDetailScreen> createState() => _PatientDetailScreenState();
}

class _PatientDetailScreenState extends State<PatientDetailScreen> with SingleTickerProviderStateMixin {
  Key _key = UniqueKey();
  late final TabController _tabs = TabController(length: 4, vsync: this);
  WearableMetric? _openMetric;
  late String _name = widget.name;

  Future<void> _rename() async {
    final api = AppScope.api(context);
    final ctl = TextEditingController(text: _name);
    final label = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Rename patient'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Name on your screens',
            helperText: "Only you see this. Leave empty to use the patient's own name.",
            helperMaxLines: 2,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    ctl.dispose();
    if (label == null || !mounted) return;
    try {
      final shown = await api.setPatientLabel(widget.patientId, label);
      if (mounted) setState(() => _name = shown);
      _reload();
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _openWearable(WearableMetric m) {
    setState(() => _openMetric = m);
    _tabs.animateTo(2);
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
      MaterialPageRoute(builder: (_) => AssignScreen(patientId: widget.patientId, patientName: _name)),
    );
    if (sent == true) _reload();
  }

  Future<void> _deactivate() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Stop $_name\'s access?'),
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

  Future<void> _share() async {
    final api = AppScope.api(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Loader<List<({String id, String name, bool shared})>>(
            load: () => api.sharing(widget.patientId),
            builder: (c, list, reload) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Share $_name with a colleague', style: c.tt.titleLarge),
              const SizedBox(height: 4),
              Text('They can read check-ins, results and watch data, for supervision or cover. Only you can send '
                  'things, rename or stop access. $_name can see who it\'s shared with, and every view is logged.',
                  style: TextStyle(color: c.sc.ink2)),
              const SizedBox(height: 8),
              if (list.isEmpty) Text('There are no other psychologists at the practice yet.', style: TextStyle(color: c.sc.ink2)),
              for (final col in list)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(col.name),
                  value: col.shared,
                  onChanged: (v) async {
                    await guarded(c, () => api.share(widget.patientId, col.id, v), done: v ? 'Shared with ${col.name}' : 'No longer shared with ${col.name}');
                    await reload();
                  },
                ),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _settings() async {
    final nav = Navigator.of(context);
    final r = await nav.push<String>(MaterialPageRoute(builder: (_) => PatientSettingsScreen(patientId: widget.patientId, name: _name)));
    if (!mounted) return;
    // archived: off the list, so back to it
    if (r == 'archived') {
      nav.pop();
    } else {
      _reload();
    }
  }

  void _menu(String v) {
    switch (v) {
      case 'settings':
        _settings();
      case 'rename':
        _rename();
      case 'deactivate':
        _deactivate();
      case 'reset':
        resetPasswordFlow(context, userId: widget.patientId, name: _name);
      case 'share':
        _share();
      case 'pdf':
        exportPatientPdf(context, widget.patientId);
      case 'excel':
        exportExcel(context, patientId: widget.patientId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final own = !widget.shared;
    return Scaffold(
      appBar: AppBar(
        title: Text(_name),
        actions: [
          if (own) IconButton(tooltip: 'Send something', onPressed: _send, icon: const Icon(Icons.send_outlined)),
          if (own)
            PopupMenuButton<String>(
              onSelected: _menu,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'settings', child: ListTile(leading: Icon(Icons.tune), title: Text('Patient settings'), subtitle: Text('Stable, archive, RADR measures'))),
                PopupMenuItem(value: 'pdf', child: ListTile(leading: Icon(Icons.picture_as_pdf_outlined), title: Text('PDF report'))),
                PopupMenuItem(value: 'excel', child: ListTile(leading: Icon(Icons.table_chart_outlined), title: Text('Export to Excel'))),
                PopupMenuItem(value: 'share', child: ListTile(leading: Icon(Icons.group_add_outlined), title: Text('Share with a colleague'))),
                PopupMenuItem(value: 'reset', child: ListTile(leading: Icon(Icons.key_outlined), title: Text('Reset password'))),
                PopupMenuItem(value: 'rename', child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Rename'))),
                PopupMenuItem(value: 'deactivate', child: ListTile(leading: Icon(Icons.block), title: Text('Stop access'))),
              ],
            ),
        ],
        bottom: TabBar(controller: _tabs, tabs: const [Tab(text: 'Overview'), Tab(text: 'Notes'), Tab(text: 'Wearable'), Tab(text: 'RADR')]),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _overview(),
          NotesTab(patientId: widget.patientId, canWrite: own),
          WearableTab(patientId: widget.patientId, initialMetric: _openMetric),
          RadrTab(patientId: widget.patientId),
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
            if (widget.shared) ...[
              Card(
                child: ListTile(
                  leading: const Icon(Icons.visibility_outlined),
                  title: Text('Shared with you by ${widget.owner}'),
                  subtitle: const Text('Read only. Ask them to send questionnaires or make changes.'),
                ),
              ),
              const SizedBox(height: 10),
            ],
            if (d.summary.selfName.isNotEmpty && d.summary.selfName != d.summary.name) ...[
              Text('Calls themselves ${d.summary.selfName} in the app', style: TextStyle(color: context.sc.ink2)),
              const SizedBox(height: 10),
            ],
            if (d.summary.stable) ...[
              Card(
                child: ListTile(
                  leading: const Icon(Icons.spa_outlined),
                  title: const Text('Marked as stable'),
                  subtitle: const Text('At the bottom of your list, nothing highlighted. Change it in Patient settings.'),
                ),
              ),
              const SizedBox(height: 10),
            ],
            if (d.summary.flags.isNotEmpty) ...[
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final f in d.summary.flags)
                  ReviewableFlag(flag: f, patientId: widget.patientId, canReview: !widget.shared, onReviewed: reload),
              ]),
              if (!widget.shared && d.summary.flags.any((f) => f.reviewable && f.reviewed == null))
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('Tap a flag to mark it as reviewed.', style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
                ),
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
            if (!widget.shared) ...[
              FilledButton.icon(onPressed: _send, icon: const Icon(Icons.send), label: const Text('Send a questionnaire or exercise')),
              const SizedBox(height: 8),
            ],
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
