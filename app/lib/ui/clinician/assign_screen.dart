// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../models.dart';
import '../theme.dart';
import '../widgets.dart';

class AssignScreen extends StatefulWidget {
  final String patientId, patientName;
  const AssignScreen({required this.patientId, required this.patientName, super.key});
  @override
  State<AssignScreen> createState() => _AssignScreenState();
}

class _AssignScreenState extends State<AssignScreen> {
  String? _picked;
  String _repeat = 'once';
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send(List<Instrument> all) async {
    final api = AppScope.api(context);
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final inst = all.firstWhere((i) => i.id == _picked);
    await api.assign(patientId: widget.patientId, instrumentId: inst.id, note: _note.text.trim(), repeat: _repeat);
    messenger.showSnackBar(SnackBar(content: Text('${inst.name} sent. ${widget.patientName.split(' ').first} will see it now.')));
    nav.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Send to ${widget.patientName.split(' ').first}')),
      body: Loader<List<Instrument>>(
        load: AppScope.api(context).instruments,
        builder: (context, all, _) {
          final sendable = all.where((i) => i.sendable).toList();
          final q = sendable.where((i) => i.isQuestionnaire).toList();
          final ex = sendable.where((i) => !i.isQuestionnaire).toList();
          final waiting = all.where((i) => i.licenceStatus == 'review').length;
          Widget option(Instrument i) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Card(
                  clipBehavior: Clip.antiAlias,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: _picked == i.id ? context.cs.primary : Colors.transparent, width: 2),
                  ),
                  child: InkWell(
                    onTap: () => setState(() => _picked = i.id),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(children: [
                        Glyph(iconFor(i), calm: !i.isQuestionnaire),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(i.name, style: context.tt.titleMedium),
                            if (i.summary.isNotEmpty) Text(i.summary, style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
                          ]),
                        ),
                        if (_picked == i.id) Icon(Icons.check_circle, color: context.cs.primary),
                      ]),
                    ),
                  ),
                ),
              );
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
            children: [
              const SectionHeader('Questionnaires'),
              for (final i in q) option(i),
              if (waiting > 0)
                Text('$waiting more in your library need a licence check before you can send them.',
                    style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
              const SectionHeader('Exercises'),
              for (final i in ex) option(i),
              const SectionHeader('How often'),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'once', label: Text('Once')),
                  ButtonSegment(value: 'daily', label: Text('Daily')),
                  ButtonSegment(value: 'weekly', label: Text('Weekly')),
                ],
                selected: {_repeat},
                onSelectionChanged: (s) => setState(() => _repeat = s.first),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _note,
                maxLength: 280,
                decoration: const InputDecoration(labelText: 'Note for the patient (optional)', hintText: 'e.g. before Thursday\'s session'),
              ),
              const SizedBox(height: 8),
              BusyButton(
                label: _picked == null ? 'Choose something to send' : 'Send ${all.firstWhere((i) => i.id == _picked).name}',
                onPressed: _picked == null ? null : () => _send(all),
              ),
            ],
          );
        },
      ),
    );
  }
}
