// SPDX-License-Identifier: AGPL-3.0-or-later
//
// OpenWorks support's view of a practice's server: feedback to look at first, the practice's
// staff (names, status, app version; never patients), and the server. The server sends nothing
// about patients to this account.
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../export/export_actions.dart';
import '../../services/api.dart';
import '../brand.dart';
import '../clinician/clinician_shell.dart' show guarded;
import '../clinician/feedback_inbox_screen.dart';
import '../clinician/server_updates_screen.dart';
import '../settings_sheet.dart';
import '../theme.dart';
import '../widgets.dart';

class SupportShell extends StatefulWidget {
  const SupportShell({super.key});
  @override
  State<SupportShell> createState() => _SupportShellState();
}

class _SupportShellState extends State<SupportShell> {
  int _tab = 0;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: IndexedStack(index: _tab, children: const [
          FeedbackInboxScreen(home: true),
          SupportStaffScreen(),
          ServerUpdatesScreen(),
        ]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.inbox_outlined), selectedIcon: Icon(Icons.inbox), label: 'To look at'),
            NavigationDestination(icon: Icon(Icons.badge_outlined), selectedIcon: Icon(Icons.badge), label: 'Staff'),
            NavigationDestination(icon: Icon(Icons.dns_outlined), selectedIcon: Icon(Icons.dns), label: 'Server'),
          ],
        ),
      );
}

/// The practice's staff for OpenWorks support: reset passwords (including a full reset after a
/// lost phone), stop and restore accounts. OpenWorks confirms it's really the person first.
class SupportStaffScreen extends StatefulWidget {
  const SupportStaffScreen({super.key});
  @override
  State<SupportStaffScreen> createState() => _SupportStaffScreenState();
}

class _SupportStaffScreenState extends State<SupportStaffScreen> {
  Key _key = UniqueKey();
  void _reload() => setState(() => _key = UniqueKey());

  Future<void> _setActive(Person p, bool active) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(active ? 'Restore ${p.name}\'s access?' : 'Stop ${p.name}\'s access?'),
        content: Text(active
            ? 'Only after confirming it\'s really them, e.g. by phoning the number on file. They sign in with their password again.'
            : 'They\'re signed out everywhere at once and can\'t sign in until OpenWorks restores the account.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(active ? 'Restore' : 'Stop access')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await guarded(context, () => AppScope.api(context).setActive(p.id, active), done: active ? 'Access restored' : 'Access stopped');
    _reload();
  }

  void _menu(Person p) {
    if (p.isSupport) {
      showSnack(context, 'OpenWorks accounts are managed on the server (deploy/accounts.sh).');
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(p.name, style: c.tt.titleMedium), subtitle: Text(p.email)),
          ListTile(
            leading: const Icon(Icons.key_outlined),
            title: const Text('Reset password'),
            subtitle: const Text('Tick "also reset two-step sign-in" for a full reset after a lost or stolen phone'),
            onTap: () {
              Navigator.pop(c);
              resetPasswordFlow(context, userId: p.id, name: p.name, staff: true);
            },
          ),
          ListTile(
            leading: Icon(p.active ? Icons.block : Icons.check_circle_outline),
            title: Text(p.active ? 'Stop access' : 'Restore access'),
            onTap: () {
              Navigator.pop(c);
              _setActive(p, !p.active);
            },
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final api = AppScope.api(context);
    return Scaffold(
      appBar: AppBar(
        title: const BrandedTitle(Text('Staff')),
        actions: [IconButton(tooltip: 'Settings', icon: const Icon(Icons.settings_outlined), onPressed: () => showSettingsSheet(context))],
      ),
      body: Loader<({List<Person> staff, String serverBuild})>(
        key: _key,
        load: api.supportStaff,
        builder: (context, d, _) {
          Widget section(String title, Iterable<Person> people) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SectionHeader(title, trailing: '${people.length}'),
                if (people.isEmpty) Text('None.', style: TextStyle(color: context.sc.ink2)),
                for (final p in people)
                  Card(
                    child: ListTile(
                      title: Text(p.name),
                      subtitle: Text([
                        p.email,
                        if (p.master) 'master clinician',
                        if (!p.twoStep) 'no two-step sign-in yet',
                        if (!p.active) 'stopped',
                        appVersionText(p.appBuild, p.appPlatform, d.serverBuild),
                      ].where((x) => x.isNotEmpty).join(' · ')),
                      trailing: p.isSupport ? null : const Icon(Icons.more_vert),
                      onTap: () => _menu(p),
                    ),
                  ),
              ]);
          return ListView(padding: const EdgeInsets.fromLTRB(16, 10, 16, 28), children: [
            Text('The practice\'s staff and their app versions. OpenWorks support never sees patients.',
                style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
            section('Psychologists', d.staff.where((p) => p.role == 'clinician')),
            section('Practice admin', d.staff.where((p) => p.role == 'admin')),
            section('OpenWorks', d.staff.where((p) => p.isSupport)),
          ]);
        },
      ),
    );
  }
}

/// "Android, up to date" / "iPhone, older version" / "not used yet", against the server's build.
String appVersionText(String build, String platform, String serverBuild) {
  if (build.isEmpty) return 'app not used yet';
  final where = switch (platform) { 'android' => 'Android', 'ios' => 'iPhone', 'web' => 'web', _ => 'app' };
  if (platform == 'web') return 'uses the web app';
  if (serverBuild.isEmpty || build == 'dev') return '$where, build $build';
  return build == serverBuild ? '$where, up to date' : '$where, older version: remind them to update';
}
