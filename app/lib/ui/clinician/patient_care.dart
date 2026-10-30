// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Looking after one patient, reached from their screen (deeper, not broader): short dated
// notes, the patient's settings (seeing them / stable / archived, and RADR measures switched off
// for this person), marking a flag as reviewed, and the archived patients list in Settings.
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../models.dart';
import '../../services/api.dart';
import '../theme.dart';
import '../widgets.dart';

/* ---------------- notes ---------------- */

/// The Notes tab: newest first. [canWrite]: the patient's own psychologist (colleagues a
/// patient is shared with can read).
class NotesTab extends StatefulWidget {
  final String patientId;
  final bool canWrite;
  const NotesTab({required this.patientId, required this.canWrite, super.key});
  @override
  State<NotesTab> createState() => _NotesTabState();
}

class _NotesTabState extends State<NotesTab> with AutomaticKeepAliveClientMixin {
  final _text = TextEditingController();
  Key _key = UniqueKey();
  bool _saving = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final t = _text.text.trim();
    if (t.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      await AppScope.api(context).addNote(widget.patientId, t);
      _text.clear();
      if (mounted) setState(() => _key = UniqueKey());
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Loader<List<Note>>(
      key: _key,
      load: () => AppScope.api(context).patientNotes(widget.patientId),
      builder: (context, notes, _) => ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 28), children: [
        if (widget.canWrite) ...[
          TextField(
            controller: _text,
            minLines: 2,
            maxLines: 6,
            maxLength: 2000,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Add a note',
              helperText: 'Only you and colleagues you share this patient with see notes. Never the patient.',
              helperMaxLines: 2,
              border: OutlineInputBorder(),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(onPressed: _saving ? null : _add, child: Text(_saving ? 'Saving...' : 'Save note')),
          ),
          const SizedBox(height: 8),
        ],
        if (notes.isEmpty) Text('No notes yet.', style: TextStyle(color: context.sc.ink2)),
        for (final n in notes)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${relTime(n.at)} · ${n.by}', style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
                const SizedBox(height: 4),
                SelectableText(n.text),
              ]),
            ),
          ),
      ]),
    );
  }
}

/* ---------------- marking a flag as reviewed ---------------- */

/// Asks for an optional note and marks [flag] as reviewed. Returns true when done.
Future<bool> reviewFlagFlow(BuildContext context, String patientId, Flag flag) async {
  final api = AppScope.api(context);
  final note = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Mark as reviewed'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(flag.label, style: c.tt.titleSmall),
        const SizedBox(height: 8),
        Text('It stays on their record with your name and the date, and no longer moves them up your list.',
            style: TextStyle(color: c.sc.ink2)),
        const SizedBox(height: 12),
        TextField(
          controller: note,
          minLines: 2,
          maxLines: 4,
          maxLength: 500,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'What you did (optional)', helperText: 'Kept with their notes', border: OutlineInputBorder()),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Mark as reviewed')),
      ],
    ),
  );
  final text = note.text.trim();
  note.dispose();
  if (ok != true) return false;
  try {
    await api.reviewFlag(patientId, flag, text);
    if (context.mounted) showSnack(context, 'Marked as reviewed');
    return true;
  } catch (e) {
    if (context.mounted) showSnack(context, errorText(e));
    return false;
  }
}

/// A flag chip that opens the review dialog (the patient's own psychologist), or shows who
/// reviewed it.
class ReviewableFlag extends StatelessWidget {
  final Flag flag;
  final String patientId;
  final bool canReview;
  final VoidCallback onReviewed;
  const ReviewableFlag({required this.flag, required this.patientId, required this.canReview, required this.onReviewed, super.key});
  @override
  Widget build(BuildContext context) {
    final r = flag.reviewed;
    if (r != null) {
      return Tooltip(
        message: 'Reviewed by ${r.by} ${relTime(r.at)}${r.note.isEmpty ? '' : ': ${r.note}'}',
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.check_circle, size: 16, color: context.sc.calm),
          const SizedBox(width: 3),
          FlagChip(flag.label, Severity.none),
        ]),
      );
    }
    if (!canReview || !flag.reviewable) return FlagChip(flag.label, flag.severity);
    return InkWell(
      borderRadius: BorderRadius.circular(99),
      onTap: () async {
        if (await reviewFlagFlow(context, patientId, flag)) onReviewed();
      },
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        FlagChip(flag.label, flag.severity),
        Icon(Icons.more_horiz, size: 16, color: context.sc.ink3),
      ]),
    );
  }
}

/* ---------------- the patient's settings ---------------- */

const radrDomainNames = {'sleep': 'Sleep', 'circadian': 'Body clock', 'activity': 'Activity', 'cardiac': 'Heart'};

class _Settings {
  final String careStatus;
  final List<Map<String, dynamic>> exclusions;
  _Settings(this.careStatus, this.exclusions);
}

/// Seeing them / stable / archived, and RADR measures switched off for this person.
class PatientSettingsScreen extends StatefulWidget {
  final String patientId, name;
  const PatientSettingsScreen({required this.patientId, required this.name, super.key});
  @override
  State<PatientSettingsScreen> createState() => _PatientSettingsScreenState();
}

class _PatientSettingsScreenState extends State<PatientSettingsScreen> {
  Key _key = UniqueKey();

  Future<_Settings> _load() async {
    final api = AppScope.api(context);
    final r = await Future.wait([api.patientSummary(widget.patientId), api.radr(widget.patientId, days: 14)]);
    final radr = r[1] as Map<String, dynamic>;
    return _Settings((r[0] as PatientSummary).careStatus, asList(radr['exclusions']).map(asMap).toList());
  }

  Future<void> _status(String status) async {
    final api = AppScope.api(context);
    final nav = Navigator.of(context);
    try {
      await api.setCareStatus(widget.patientId, status);
      if (!mounted) return;
      if (status == 'archived') {
        showSnack(context, '${widget.name} is archived. Bring them back from Settings > Archived patients.');
        nav.pop('archived');
        return;
      }
      showSnack(context, status == 'stable' ? 'Marked as stable' : 'Back to usual');
      setState(() => _key = UniqueKey());
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    }
  }

  Future<void> _toggle(String domain, bool countIt) async {
    final api = AppScope.api(context);
    var reason = '';
    if (!countIt) {
      final ctl = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('Stop counting ${radrDomainNames[domain]} in RADR?'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Steady still collects and shows it. It just won\'t count in ${widget.name}\'s RADR or move them up your list.',
                style: TextStyle(color: c.sc.ink2)),
            const SizedBox(height: 12),
            TextField(
              controller: ctl,
              autofocus: true,
              maxLength: 200,
              decoration: const InputDecoration(labelText: 'Why', hintText: 'e.g. shift worker', border: OutlineInputBorder()),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Stop counting')),
          ],
        ),
      );
      reason = ctl.text.trim();
      ctl.dispose();
      if (ok != true) return;
      if (reason.isEmpty) {
        if (mounted) showSnack(context, 'Say briefly why. It shows wherever RADR does.');
        return;
      }
    }
    try {
      await api.setRadrExclusion(widget.patientId, domain, !countIt, reason: reason);
      if (mounted) setState(() => _key = UniqueKey());
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('${widget.name}: settings')),
        body: Loader<_Settings>(
          key: _key,
          load: _load,
          builder: (context, st, _) {
            final off = {for (final x in st.exclusions) '${x['domain']}': x};
            Widget status(String value, String title, String what) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(st.careStatus == value ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                      color: st.careStatus == value ? context.cs.primary : context.sc.ink3),
                  title: Text(title),
                  subtitle: Text(what),
                  onTap: st.careStatus == value ? null : () => _status(value),
                );
            return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 28), children: [
              const SectionHeader('Where they are in your work'),
              status('', 'Seeing them', 'On your list in the usual order: those needing attention first.'),
              status('stable', 'Stable, ease off',
                  'Still on your list, at the bottom, with nothing highlighted. Their check-ins and flags are still recorded.'),
              status('archived', 'Archive',
                  'No longer seeing them: off your list. Their account and records stay. Bring them back from Settings > Archived patients.'),
              const SizedBox(height: 16),
              const SectionHeader('RADR measures for this patient'),
              Text(
                'Switch a measure off when it doesn\'t fit this person, for example sleep for a shift worker. The data is still '
                'collected and shown; it just isn\'t counted in their RADR. Each change shows with the date, who and why.',
                style: context.tt.bodySmall?.copyWith(color: context.sc.ink2),
              ),
              for (final d in radrDomainNames.keys)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(radrDomainNames[d]!),
                  subtitle: off[d] == null
                      ? const Text('Counted')
                      : Text('Not counted since ${'${off[d]!['since'] ?? ''}'.split('T').first}, by ${off[d]!['by'] ?? ''}: ${off[d]!['reason'] ?? ''}'),
                  value: off[d] == null,
                  onChanged: (v) => _toggle(d, v),
                ),
            ]);
          },
        ),
      );
}

/* ---------------- archived patients (Settings) ---------------- */

class ArchivedPatientsScreen extends StatefulWidget {
  const ArchivedPatientsScreen({super.key});
  @override
  State<ArchivedPatientsScreen> createState() => _ArchivedPatientsScreenState();
}

class _ArchivedPatientsScreenState extends State<ArchivedPatientsScreen> {
  Key _key = UniqueKey();

  @override
  Widget build(BuildContext context) {
    final api = AppScope.api(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Archived patients')),
      body: Loader<List<({String id, String name, DateTime? archivedAt})>>(
        key: _key,
        load: api.archivedPatients,
        builder: (context, list, _) => ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 28), children: [
          Text('Patients you\'re no longer seeing. They\'re off your list; their accounts and records stay.',
              style: TextStyle(color: context.sc.ink2)),
          const SizedBox(height: 8),
          if (list.isEmpty) Text('Nobody is archived.', style: TextStyle(color: context.sc.ink2)),
          for (final p in list)
            Card(
              child: ListTile(
                title: Text(p.name),
                subtitle: Text(p.archivedAt == null ? 'Archived' : 'Archived ${relTime(p.archivedAt)}'),
                trailing: TextButton(
                  onPressed: () async {
                    try {
                      await api.setCareStatus(p.id, '');
                      if (!context.mounted) return;
                      showSnack(context, '${p.name} is back on your list');
                      setState(() => _key = UniqueKey());
                    } catch (e) {
                      if (context.mounted) showSnack(context, errorText(e));
                    }
                  },
                  child: const Text('Reactivate'),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
