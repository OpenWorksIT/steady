// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../models.dart';
import '../theme.dart';
import '../widgets.dart';
import 'builder_screen.dart';
import 'clinician_shell.dart';
import 'import_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  Key _key = UniqueKey();
  void _reload() => setState(() => _key = UniqueKey());

  Future<void> _push(Widget w) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => w));
    if (changed == true) _reload();
  }

  void _add() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.edit_note),
            title: const Text('Create a questionnaire or exercise'),
            subtitle: const Text('Write your own questions and scoring'),
            onTap: () {
              Navigator.pop(c);
              _push(const BuilderScreen());
            },
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('Import'),
            subtitle: const Text('From the open ReproSchema library, a file, or pasted JSON'),
            onTap: () {
              Navigator.pop(c);
              _push(const ImportScreen());
            },
          ),
          const SizedBox(height: 12),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final api = AppScope.api(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Library')),
      floatingActionButton: FloatingActionButton.extended(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Add')),
      body: Loader<List<Instrument>>(
        key: _key,
        load: () => api.instruments(includeArchived: true),
        builder: (context, all, reload) {
          final ready = all.where((i) => i.sendable).toList();
          final review = all.where((i) => i.active && i.licenceStatus == 'review').toList();
          final other = all.where((i) => !i.active || i.licenceStatus == 'blocked').toList();
          Widget row(Instrument i) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Card(
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => _showDetail(i),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(children: [
                        Glyph(iconFor(i), calm: !i.isQuestionnaire),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(i.name, style: context.tt.titleMedium),
                            Text(i.fullName.isNotEmpty ? i.fullName : i.summary, style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
                            Text(i.sourceName, style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
                          ]),
                        ),
                        _statusChip(i),
                      ]),
                    ),
                  ),
                ),
              );
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
            children: [
              SectionHeader('Ready to send', trailing: '${ready.length}'),
              for (final i in ready) row(i),
              if (review.isNotEmpty) ...[
                SectionHeader('Needs a licence check', trailing: '${review.length}'),
                Text('Confirm the practice may use these before sending them.', style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
                const SizedBox(height: 6),
                for (final i in review) row(i),
              ],
              if (other.isNotEmpty) ...[
                const SectionHeader('Archived'),
                for (final i in other) row(i),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _statusChip(Instrument i) => switch (i.licenceStatus) {
        _ when !i.active => const FlagChip('Archived', Severity.none),
        'cleared' => const FlagChip('Cleared', Severity.none),
        'custom' => const FlagChip('Own', Severity.info),
        'review' => const FlagChip('Check licence', Severity.warn),
        _ => const FlagChip('Blocked', Severity.alert),
      };

  void _showDetail(Instrument i) {
    final api = AppScope.api(context);
    final mine = !i.builtin && i.createdBy == api.myId;
    final editable = mine && i.sourceName == 'Created in Steady';
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        builder: (c, sc) => ListView(
          controller: sc,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
          children: [
            Text(i.name, style: c.tt.headlineSmall),
            if (i.fullName.isNotEmpty) Text(i.fullName, style: TextStyle(color: c.sc.ink2)),
            const SizedBox(height: 10),
            Text('Licence: ${i.licenceName.isEmpty ? 'not stated' : i.licenceName}', style: c.tt.bodySmall),
            if (i.licenceUrl.isNotEmpty) SelectableText(i.licenceUrl, style: c.tt.bodySmall?.copyWith(color: c.cs.primary)),
            Text('Source: ${i.sourceName}', style: c.tt.bodySmall),
            const SizedBox(height: 14),
            if (i.licenceStatus == 'review' && i.active)
              FilledButton(
                onPressed: () async {
                  Navigator.pop(c);
                  await _confirmLicence(i);
                },
                child: const Text('Confirm the practice may use this'),
              ),
            if (!i.builtin || i.isQuestionnaire) ...[
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () {
                  Navigator.pop(c);
                  _push(BuilderScreen(copyFrom: i));
                },
                child: const Text('Use as a starting point for a new one'),
              ),
            ],
            if (editable) ...[
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () {
                  Navigator.pop(c);
                  _push(BuilderScreen(edit: i));
                },
                child: const Text('Edit'),
              ),
            ],
            if (mine) ...[
              if (i.active) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () async {
                    Navigator.pop(c);
                    await guarded(context, () => api.archiveInstrument(i.id), done: '${i.name} archived');
                    _reload();
                  },
                  child: const Text('Archive'),
                ),
              ],
            ],
            const SizedBox(height: 16),
            if (i.instructions.isNotEmpty) Text(i.instructions, style: TextStyle(color: c.sc.ink2)),
            const SizedBox(height: 8),
            for (final (n, it) in i.items.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('${n + 1}. ${it.text}${it.type == 'choice' ? '' : ' (${it.type})'}${it.showIf.isNotEmpty ? ' (conditional)' : ''}'),
              ),
            if (i.exercise != null)
              for (final s in i.exercise!.type == 'steps'
                  ? i.exercise!.steps.map((s) => '${s.title}: ${s.prompt}')
                  : i.exercise!.phases.map((p) => '${p.label} ${p.seconds}s'))
                Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(s)),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmLicence(Instrument i) async {
    var ticked = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text('Use ${i.name}?'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(i.licenceName.isEmpty ? 'No licence information came with this instrument.' : i.licenceName),
            const SizedBox(height: 12),
            CheckboxListTile(
              value: ticked,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              onChanged: (v) => set(() => ticked = v ?? false),
              title: const Text('I confirm the practice has the right to use this instrument with patients.'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: ticked ? () => Navigator.pop(c, true) : null, child: const Text('Confirm')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    await guarded(context, () => AppScope.api(context).confirmLicence(i.id), done: '${i.name} is ready to send');
    _reload();
  }
}
