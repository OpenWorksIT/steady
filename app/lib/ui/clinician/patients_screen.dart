// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_state.dart';
import '../../models.dart';
import '../../services/api.dart';
import '../settings_sheet.dart';
import '../theme.dart';
import '../widgets.dart';
import 'clinician_shell.dart';
import 'patient_detail_screen.dart';

class PatientsScreen extends StatefulWidget {
  final ClinicianBus bus;
  const PatientsScreen({required this.bus, super.key});
  @override
  State<PatientsScreen> createState() => _PatientsScreenState();
}

class _PatientsScreenState extends State<PatientsScreen> with BusReload {
  @override
  ClinicianBus get bus => widget.bus;

  @override
  void initState() {
    super.initState();
    listenToBus();
  }

  @override
  void dispose() {
    stopListening();
    super.dispose();
  }

  Future<void> _invite() async {
    final label = TextEditingController();
    final api = AppScope.api(context);
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Invite a patient'),
        content: TextField(
          controller: label,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Note for yourself (optional)', hintText: 'e.g. first name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Create code')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    try {
      final inv = await api.createInvite(label.text.trim());
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Invite code'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            SelectableText(inv.code, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700, letterSpacing: 2)),
            const SizedBox(height: 8),
            Text('Give this to your patient. They install Steady, tap "I have an invite code" and enter it. '
                'It works once and expires on ${inv.expires.day}/${inv.expires.month}/${inv.expires.year}.'),
          ]),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: inv.code));
                Navigator.pop(c);
                showSnack(context, 'Code copied');
              },
              child: const Text('Copy'),
            ),
            FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Done')),
          ],
        ),
      );
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    } finally {
      label.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = AppScope.api(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Patients'),
        actions: [IconButton(tooltip: 'Settings', icon: const Icon(Icons.settings_outlined), onPressed: () => showSettingsSheet(context))],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _invite,
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Invite'),
      ),
      body: Loader<List<PatientSummary>>(
        key: reloadKey,
        load: api.overview,
        builder: (context, list, reload) {
          if (list.isEmpty) {
            return ListView(padding: const EdgeInsets.all(24), children: [
              Text('No patients yet.', style: context.tt.titleMedium),
              const SizedBox(height: 6),
              Text('Tap Invite to create a code for a patient. They join with it from their own phone.',
                  style: TextStyle(color: context.sc.ink2)),
            ]);
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
            children: [
              for (final p in list)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _PatientRow(
                    p,
                    onTap: () async {
                      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PatientDetailScreen(patientId: p.id, name: p.name)));
                      reload();
                    },
                  ),
                ),
              const SizedBox(height: 6),
              Text('Flags help you decide who to look at first. They are review aids, not a diagnosis or a risk score.',
                  style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
            ],
          );
        },
      ),
    );
  }
}

class _PatientRow extends StatelessWidget {
  final PatientSummary p;
  final VoidCallback onTap;
  const _PatientRow(this.p, {required this.onTap});
  @override
  Widget build(BuildContext context) {
    final last = p.lastCheckinAt == null ? 'No check-ins yet' : 'Last check-in ${relTime(p.lastCheckinAt)} · mood ${p.lastMood}/5';
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Avatar(p.initials),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p.name, style: context.tt.titleMedium),
                  Text(last, style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
                  if (p.wearable.connected)
                    Row(children: [
                      Icon(Icons.watch_outlined, size: 13, color: context.sc.ink3),
                      const SizedBox(width: 3),
                      Text('${p.wearable.days14} of 14 days', style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
                    ]),
                ]),
              ),
              Sparkline(p.mood),
            ]),
            if (p.flags.isNotEmpty) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(left: 52),
                child: Wrap(spacing: 6, runSpacing: 6, children: [for (final f in p.flags.take(3)) FlagChip(f.label, f.severity)]),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}
