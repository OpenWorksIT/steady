// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../models.dart';
import '../theme.dart';
import '../widgets.dart';
import 'clinician_shell.dart';
import 'patient_detail_screen.dart';
import 'result_screen.dart';

class AlertsScreen extends StatefulWidget {
  final ClinicianBus bus;
  final Future<void> Function() onRead;
  const AlertsScreen({required this.bus, required this.onRead, super.key});
  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> with BusReload {
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

  Future<void> _open(AppNotification n) async {
    final api = AppScope.api(context);
    final nav = Navigator.of(context);
    if (!n.read) {
      try {
        await api.markRead(n.id);
      } catch (_) {}
      await widget.onRead();
    }
    if (n.assignmentId.isNotEmpty) {
      await nav.push(MaterialPageRoute(builder: (_) => ResultScreen(assignmentId: n.assignmentId)));
    } else if (n.patientId.isNotEmpty) {
      final name = n.title.replaceAll(RegExp(r' (checked in|joined|completed .*|did .*)$'), '');
      await nav.push(MaterialPageRoute(builder: (_) => PatientDetailScreen(patientId: n.patientId, name: name)));
    }
    reloadNow();
  }

  @override
  Widget build(BuildContext context) {
    final api = AppScope.api(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Alerts')),
      body: Loader<List<AppNotification>>(
        key: reloadKey,
        load: api.notifications,
        builder: (context, list, reload) {
          if (list.isEmpty) {
            return ListView(padding: const EdgeInsets.all(24), children: [
              Text('Nothing new. When a patient checks in or finishes something, it shows here and on your lock screen.',
                  style: TextStyle(color: context.sc.ink2)),
            ]);
          }
          final unread = list.where((n) => !n.read).toList();
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
            children: [
              if (unread.isNotEmpty)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => guarded(context, () async {
                      await api.markAllRead(unread);
                      await widget.onRead();
                      reload();
                    }),
                    child: const Text('Mark all as read'),
                  ),
                ),
              for (final n in list)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Card(
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => _open(n),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 6, right: 10),
                            child: CircleAvatar(
                              radius: 4,
                              backgroundColor: n.read ? Colors.transparent : context.sc.forSeverity(n.severity == Severity.none ? Severity.info : n.severity, context.cs).fg,
                            ),
                          ),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(n.title, style: context.tt.titleMedium?.copyWith(fontWeight: n.read ? FontWeight.w500 : FontWeight.w700)),
                              if (n.body.isNotEmpty) Text(n.body, style: TextStyle(color: context.sc.ink2)),
                              const SizedBox(height: 2),
                              Text(relTime(n.created), style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
                            ]),
                          ),
                          if (n.severity == Severity.alert || n.severity == Severity.warn)
                            FlagChip(n.severity == Severity.alert ? 'Review' : 'Note', n.severity),
                        ]),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
