// SPDX-License-Identifier: AGPL-3.0-or-later
// The practice's people, for the master clinician and the practice admin: names, roles, and for
// each patient whether they're set up and connected (agreements, app version, notifications,
// watch sharing and permissions, last check-in and upload dates). Nothing here shows check-ins,
// scores or watch data (the server doesn't send them).
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../export/export_actions.dart';
import '../../services/api.dart';
import '../brand.dart';
import '../clinician/clinician_shell.dart' show guarded;
import '../clinician/invite_dialog.dart';
import '../settings_sheet.dart';
import '../theme.dart';
import '../widgets.dart';
import 'support_shell.dart' show appVersionText;

typedef _People = ({List<Person> patients, List<Person> clinicians, List<Person> admins, String serverBuild});

class PeopleScreen extends StatefulWidget {
  const PeopleScreen({super.key});
  @override
  State<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends State<PeopleScreen> {
  Key _key = UniqueKey();
  String _serverBuild = '';
  String _query = '';
  void _reload() => setState(() => _key = UniqueKey());

  bool get _master => AppScope.api(context).isMaster;

  Future<String?> _pickClinician({String? exceptId, String title = 'Which psychologist?'}) async {
    final list = await AppScope.api(context).clinicians();
    if (!mounted) return null;
    final choices = list.where((c) => c.id != exceptId).toList();
    if (choices.isEmpty) {
      showSnack(context, 'There are no other active psychologists.');
      return null;
    }
    return showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: Text(title),
        children: [
          for (final cl in choices)
            SimpleDialogOption(onPressed: () => Navigator.pop(c, cl.id), child: Text(cl.you ? '${cl.name} (you)' : cl.name)),
        ],
      ),
    );
  }

  Future<void> _invite() async {
    final api = AppScope.api(context);
    final clinicianId = await _pickClinician(title: 'Invite a patient for');
    if (clinicianId == null || !mounted) return;
    final label = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Invite a patient'),
        content: TextField(
          controller: label,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: "Patient's name",
            helperText: 'How the psychologist will see them. The patient chooses their own name in the app.',
            helperMaxLines: 2,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Create code')),
        ],
      ),
    );
    final name = label.text.trim();
    label.dispose();
    if (go != true || !mounted) return;
    try {
      final list = await api.clinicians();
      final inv = await api.createInviteFor(clinicianId, name);
      if (!mounted) return;
      final who = list.where((c) => c.id == clinicianId).map((c) => c.name).firstOrNull;
      await showInviteCode(context, api.serverUrl, inv.code, inv.expires, forClinician: who);
      _reload();
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    }
  }

  Future<void> _addStaff(String role) async {
    final name = TextEditingController(), email = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(role == 'admin' ? 'Add an administrator' : 'Add a psychologist'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, autofocus: true, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Name')),
          const SizedBox(height: 10),
          TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email')),
          const SizedBox(height: 10),
          Text(
            role == 'admin'
                ? 'Administrators see names only: they invite patients, reset patients\' passwords and stop or restore access.'
                : 'They get a temporary password to sign in with, then choose their own and set up two-step sign-in.',
            style: TextStyle(color: c.sc.ink2),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Add')),
        ],
      ),
    );
    final n = name.text.trim(), m = email.text.trim();
    name.dispose();
    email.dispose();
    if (go != true || !mounted) return;
    try {
      final pw = await AppScope.api(context).createStaff(role: role, name: n, email: m);
      if (mounted) await showTemporaryPassword(context, n, pw);
      _reload();
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    }
  }

  Future<void> _setActive(Person p, bool active) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(active ? 'Restore ${p.name}\'s access?' : 'Stop ${p.name}\'s access?'),
        content: Text(active
            ? 'They can sign in again with their password.'
            : 'They\'re signed out everywhere and can\'t sign in.${p.role == 'patient' ? ' Waiting activities are cancelled. Their records stay.' : ''}'),
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

  Future<void> _move(Person p) async {
    final to = await _pickClinician(exceptId: p.clinicianId, title: 'Move ${p.name} to');
    if (to == null || !mounted) return;
    await guarded(context, () => AppScope.api(context).reassignPatient(p.id, to), done: 'Moved. Both psychologists are told.');
    _reload();
  }

  void _patientMenu(Person p) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(p.name, style: c.tt.titleMedium), subtitle: Text('With ${p.clinicianName.isEmpty ? 'no psychologist' : p.clinicianName}')),
          if (p.status?.watchLapsed == true)
            ListTile(
              leading: const Icon(Icons.watch_outlined),
              title: const Text('Remind them to reconnect their watch'),
              subtitle: const Text('A notice in their app; no health details'),
              onTap: () {
                Navigator.pop(c);
                guarded(context, () => AppScope.api(context).remindWatch(p.id), done: 'Reminder sent');
              },
            ),
          ListTile(
            leading: const Icon(Icons.key_outlined),
            title: const Text('Reset password'),
            onTap: () {
              Navigator.pop(c);
              resetPasswordFlow(context, userId: p.id, name: p.name);
            },
          ),
          ListTile(
            leading: const Icon(Icons.swap_horiz),
            title: const Text('Move to another psychologist'),
            onTap: () {
              Navigator.pop(c);
              _move(p);
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

  /// Psychologists: the master clinician or the practice admin. The practice admin: the master
  /// clinician. The master clinician and OpenWorks accounts: OpenWorks (the server checks too).
  bool _canReset(Person p) {
    final api = AppScope.api(context);
    if (p.id == api.myId || p.isSupport || p.master) return false;
    if (p.role == 'admin') return api.isMaster;
    return api.isManager;
  }

  /// Stopping is easy (master clinician, practice admin); restoring is OpenWorks'.
  bool _canStop(Person p) => p.active && p.id != AppScope.api(context).myId && !p.isSupport;

  void _staffMenu(Person p) {
    if (!_canReset(p) && !_canStop(p)) {
      showSnack(
          context,
          p.isSupport
              ? 'OpenWorks accounts are managed by OpenWorks.'
              : p.master
                  ? 'The master clinician\'s password is reset by OpenWorks IT.'
                  : !p.active
                      ? 'Ask OpenWorks IT to restore this account. They check it\'s really them first.'
                      : 'Change your own password in Settings.');
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(p.name, style: c.tt.titleMedium), subtitle: Text(p.email)),
          if (_canReset(p))
            ListTile(
              leading: const Icon(Icons.key_outlined),
              title: const Text('Reset password'),
              subtitle: const Text('Lost phone with their authenticator? OpenWorks IT does a full reset.'),
              onTap: () {
                Navigator.pop(c);
                resetPasswordFlow(context, userId: p.id, name: p.name);
              },
            ),
          if (_canStop(p))
            ListTile(
              leading: const Icon(Icons.block),
              title: const Text('Stop access now'),
              subtitle: const Text('Signs them out everywhere, e.g. a lost or stolen phone. Only OpenWorks IT can restore it.'),
              onTap: () {
                Navigator.pop(c);
                _setActive(p, false);
              },
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final api = AppScope.api(context);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const BrandedTitle(Text('Practice')),
          actions: [IconButton(tooltip: 'Settings', icon: const Icon(Icons.settings_outlined), onPressed: () => showSettingsSheet(context))],
          bottom: const TabBar(tabs: [Tab(text: 'Patients'), Tab(text: 'Staff')]),
        ),
        floatingActionButton: Builder(
          builder: (context) => FloatingActionButton.extended(
            onPressed: () {
              final tab = DefaultTabController.of(context).index;
              if (tab == 0) {
                _invite();
              } else if (_master) {
                showModalBottomSheet<void>(
                  context: context,
                  showDragHandle: true,
                  builder: (c) => SafeArea(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      ListTile(leading: const Icon(Icons.psychology_outlined), title: const Text('Add a psychologist'), onTap: () {
                        Navigator.pop(c);
                        _addStaff('clinician');
                      }),
                      ListTile(leading: const Icon(Icons.badge_outlined), title: const Text('Add an administrator'), onTap: () {
                        Navigator.pop(c);
                        _addStaff('admin');
                      }),
                    ]),
                  ),
                );
              } else {
                showSnack(context, 'New staff accounts are added by the master clinician.');
              }
            },
            icon: const Icon(Icons.person_add_alt),
            label: const Text('Add'),
          ),
        ),
        body: Loader<_People>(
          key: _key,
          load: api.people,
          builder: (context, d, reload) {
            _serverBuild = d.serverBuild;
            final q = _query.toLowerCase();
            final pats = d.patients.where((p) => q.isEmpty || p.name.toLowerCase().contains(q) || p.clinicianName.toLowerCase().contains(q)).toList();
            return TabBarView(children: [
              ListView(padding: const EdgeInsets.fromLTRB(16, 10, 16, 96), children: [
                TextField(
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search), labelText: 'Find a patient or psychologist'),
                  onChanged: (v) => setState(() => _query = v),
                ),
                const SizedBox(height: 8),
                Text('Whether each patient is set up and connected. What they share is only for their own psychologist.',
                    style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
                const SizedBox(height: 8),
                if (pats.isEmpty) Text('No patients.', style: TextStyle(color: context.sc.ink2)),
                for (final p in pats)
                  Card(
                    child: ListTile(
                      leading: Avatar(_initials(p.name)),
                      title: Text(p.name),
                      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${p.clinicianName.isEmpty ? 'No psychologist' : p.clinicianName}${p.active ? '' : ' · stopped'}'
                            '${p.status?.careStatus == 'archived' ? ' · archived' : ''}'),
                        if (p.status != null) _StatusLine(p, d.serverBuild),
                      ]),
                      isThreeLine: p.status != null,
                      trailing: const Icon(Icons.more_vert),
                      onTap: () => _patientMenu(p),
                    ),
                  ),
              ]),
              ListView(padding: const EdgeInsets.fromLTRB(16, 10, 16, 96), children: [
                SectionHeader('Psychologists', trailing: '${d.clinicians.length}'),
                for (final p in d.clinicians) _staffTile(context, p),
                const SizedBox(height: 8),
                SectionHeader('Administrators and support', trailing: '${d.admins.length}'),
                if (d.admins.isEmpty) Text('None yet.', style: TextStyle(color: context.sc.ink2)),
                for (final p in d.admins) _staffTile(context, p),
              ]),
            ]);
          },
        ),
      ),
    );
  }

  Widget _staffTile(BuildContext context, Person p) => Card(
        child: ListTile(
          leading: Avatar(_initials(p.name)),
          title: Text(p.name),
          subtitle: Text([
            p.email,
            if (p.master) 'master clinician',
            if (p.serverAdmin) 'server admin',
            if (p.isSupport) 'OpenWorks IT',
            if (!p.twoStep) 'no two-step sign-in yet',
            if (!p.active) 'stopped',
            if (!p.isSupport) appVersionText(p.appBuild, p.appPlatform, _serverBuild),
          ].join(' · ')),
          trailing: _canReset(p) || _canStop(p) ? const Icon(Icons.more_vert) : null,
          onTap: () => _staffMenu(p),
        ),
      );
}

String _initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  return (parts.first[0] + (parts.length > 1 ? parts.last[0] : '')).toUpperCase();
}

/// One line of icons and words: agreements, app, notifications, watch, last check-in.
class _StatusLine extends StatelessWidget {
  final Person p;
  final String serverBuild;
  const _StatusLine(this.p, this.serverBuild);
  @override
  Widget build(BuildContext context) {
    final st = p.status!;
    final warn = context.sc.warn, ok = context.sc.ink3;
    Widget item(IconData icon, String text, {bool bad = false}) => Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: bad ? warn : ok),
          const SizedBox(width: 3),
          Text(text, style: context.tt.bodySmall?.copyWith(color: bad ? warn : context.sc.ink2, fontWeight: bad ? FontWeight.w600 : null)),
        ]);
    final app = appVersionText(p.appBuild, p.appPlatform, serverBuild);
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Wrap(spacing: 10, runSpacing: 2, children: [
        if (st.consentAt == null)
          item(Icons.assignment_late_outlined, 'consent not given', bad: true)
        else if (!st.consentCurrent)
          item(Icons.assignment_outlined, 'older consent (${st.consentVersion})', bad: true),
        item(Icons.phone_android, app, bad: app.contains('older') || app.contains('not used')),
        if (p.appPlatform != 'web') item(Icons.notifications_none, st.notifications.isEmpty ? 'no notifications' : 'notifications on', bad: st.notifications.isEmpty),
        if (!st.watchSharing)
          item(Icons.watch_outlined, 'watch not shared')
        else if (st.watchLapsed)
          item(Icons.watch_off_outlined, 'watch permissions lapsed ${relTime(st.watchPermissionSince)}', bad: true)
        else
          item(Icons.watch_outlined, st.watchLastDay.isEmpty ? 'watch: nothing yet' : 'watch synced ${st.watchLastDay}'),
        item(Icons.edit_note, st.lastCheckinAt == null ? 'no check-in in 60 days' : 'checked in ${relTime(st.lastCheckinAt)}'),
      ]),
    );
  }
}
