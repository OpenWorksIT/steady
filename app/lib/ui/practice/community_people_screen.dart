// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Settings > Practice > Community (the master psychologist): which of the practice's staff are in
// Steady Community. Someone switched on can open the Community tab once OpenWorks IT has approved
// them in its fleet view; someone switched off is out straight away (the bridge's list follows).
// Practice administrators see the Steady manual only, there.
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../services/api.dart';
import '../theme.dart';
import '../widgets.dart';

class CommunityPeopleScreen extends StatefulWidget {
  const CommunityPeopleScreen({super.key});
  @override
  State<CommunityPeopleScreen> createState() => _CommunityPeopleScreenState();
}

class _CommunityPeopleScreenState extends State<CommunityPeopleScreen> {
  final Map<String, bool> _changed = {};
  final Set<String> _busy = {};

  Future<void> _set(Person p, bool on) async {
    final api = AppScope.api(context);
    setState(() => _busy.add(p.id));
    try {
      final saved = await api.setCommunity(p.id, on);
      if (!mounted) return;
      setState(() => _changed[p.id] = saved.community);
      showSnack(
          context,
          on
              ? '${p.name} is in. They can open the Community tab once OpenWorks IT has approved them.'
              : '${p.name} is out of the community.');
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    } finally {
      if (mounted) setState(() => _busy.remove(p.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = AppScope.api(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Community')),
      body: Loader<({List<Person> patients, List<Person> clinicians, List<Person> admins, String serverBuild})>(
        load: api.people,
        builder: (context, d, _) {
          final staff = [...d.clinicians, ...d.admins].where((p) => p.active).toList();
          return ListView(padding: const EdgeInsets.fromLTRB(16, 10, 16, 28), children: [
            Text(
                'Who from the practice is in Steady Community. Someone you switch on can open the Community tab once '
                'OpenWorks IT has approved them. Someone you switch off is out straight away. '
                'Administrators see the Steady manual only.',
                style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
            const SizedBox(height: 8),
            if (staff.isEmpty) Text('No active staff yet.', style: TextStyle(color: context.sc.ink2)),
            for (final p in staff)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(p.name),
                subtitle: Text('${p.role == 'admin' ? 'Administrator' : 'Psychologist'} · ${p.email}'),
                value: _changed[p.id] ?? p.community,
                onChanged: _busy.contains(p.id) ? null : (v) => _set(p, v),
              ),
          ]);
        },
      ),
    );
  }
}
