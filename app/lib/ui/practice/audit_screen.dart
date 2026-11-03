// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Settings > Audit report (master clinician and practice admin): who opened or changed what, for
// a patient's access request (POPIA section 23) or a review. Reading it is logged too.
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../services/api.dart';
import '../clinician/server_health.dart';
import '../theme.dart';
import '../widgets.dart';

const _actions = {
  'patients.overview': 'Opened the patient list',
  'patient.summary': 'Opened a patient',
  'patient.biometrics': 'Looked at watch data',
  'patient.radr': 'Looked at RADR',
  'patient.notes': 'Read notes',
  'patient.note.add': 'Added a note',
  'patient.export': 'Exported a patient',
  'patients.export': 'Exported all patients',
  'patient.flag.review': 'Marked a flag as reviewed',
  'patient.export.heidi': 'Exported a patient for Heidi',
  'account.self-lock': 'Locked their own account',
  'account.device.linked': 'Linked a device',
  'account.device.removed': 'Removed a device',
  'auth.device.code-sent': 'Asked for a device code',
  'account.password-changed': 'Changed their password',
  'patient.share': 'Shared a patient',
  'patient.unshare': 'Stopped sharing a patient',
  'patient.reassign': 'Moved a patient',
  'patient.join': 'Joined with an invite',
  'patient.remind-watch': 'Reminded to reconnect the watch',
  'account.reset-password': 'Reset a password',
  'account.stop': 'Stopped an account',
  'account.restore': 'Restored an account',
  'account.create': 'Added a staff account',
  'audit.read': 'Read the audit report',
  'people.list': 'Opened the practice\'s people',
};

String _describe(String action) {
  if (_actions[action] != null) return _actions[action]!;
  if (action.startsWith('list.') || action.startsWith('view.')) return 'Read ${action.split('.').last}';
  if (action.startsWith('patient.care')) return 'Changed a patient\'s care settings';
  if (action.startsWith('patient.radr.')) return 'Changed RADR measures';
  return action;
}

class AuditScreen extends StatefulWidget {
  const AuditScreen({super.key});
  @override
  State<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends State<AuditScreen> {
  int _days = 7;
  String _query = '';
  Key _key = UniqueKey();

  @override
  Widget build(BuildContext context) {
    final api = AppScope.api(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Audit report')),
      body: Loader<({List<AuditRow> rows, bool truncated})>(
        key: _key,
        load: () => api.audit(days: _days),
        builder: (context, d, _) {
          final q = _query.toLowerCase();
          final rows = d.rows
              .where((r) => q.isEmpty || r.actor.toLowerCase().contains(q) || r.patient.toLowerCase().contains(q) || _describe(r.action).toLowerCase().contains(q))
              .toList();
          return ListView(padding: const EdgeInsets.fromLTRB(16, 10, 16, 28), children: [
            Text('Who opened or changed what, for a patient\'s request to see who accessed their information, or a review. '
                'Reading this report is logged too.', style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
            const SizedBox(height: 10),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('Day')),
                ButtonSegment(value: 7, label: Text('Week')),
                ButtonSegment(value: 30, label: Text('Month')),
                ButtonSegment(value: 365, label: Text('Year')),
              ],
              selected: {_days},
              onSelectionChanged: (v) => setState(() {
                _days = v.first;
                _key = UniqueKey();
              }),
            ),
            const SizedBox(height: 8),
            TextField(
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), labelText: 'Find a person, patient or action'),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            if (d.truncated) Text('Showing the newest 5000. Choose a shorter period to see everything.', style: TextStyle(color: context.sc.warn)),
            if (rows.isEmpty) Text('Nothing in this period.', style: TextStyle(color: context.sc.ink2)),
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${r.actor} · ${_describe(r.action)}', style: context.tt.titleSmall),
                      Text([relTime(r.at), if (r.patient.isNotEmpty) 'patient: ${r.patient}', if (r.ip.isNotEmpty) 'from ${r.ip}'].join(' · '),
                          style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
                    ]),
                  ),
                ),
              ),
          ]);
        },
      ),
    );
  }
}

/// Settings > Server health, for the practice admin (who sees it but doesn't start updates).
class ServerHealthScreen extends StatelessWidget {
  const ServerHealthScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Server health')),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 10, 16, 28), children: [
          const ServerHealthCard(),
          const SizedBox(height: 8),
          Text('Updates are installed by OpenWorks IT or the master clinician.', style: TextStyle(color: context.sc.ink3)),
        ]),
      );
}
