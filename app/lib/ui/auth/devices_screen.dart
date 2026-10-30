// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Settings > Your devices (practice staff): the phones and browsers linked to your account,
// removing one (an old phone, a shared computer), and locking your account if a phone is lost.
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../services/api.dart';
import '../clinician/clinician_shell.dart' show guarded;
import '../theme.dart';
import '../widgets.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});
  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  Key _key = UniqueKey();
  void _reload() => setState(() => _key = UniqueKey());

  Future<void> _remove(LinkedDevice d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Remove ${d.name}?'),
        content: Text(d.current
            ? 'This device stays signed in for now. Next time you sign in on it, we email you a new code to link it again.'
            : 'It\'s signed out at once and can\'t sign in again without a new code by email. Your other devices stay signed in.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await guarded(context, () => AppScope.api(context).removeDevice(d.id), done: 'Removed ${d.name}');
    _reload();
  }

  Future<void> _lock() async {
    final api = AppScope.api(context);
    final password = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Lock your account?'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('If a phone with Steady on it is lost or stolen. You\'re signed out everywhere, including here, and every '
              'device is unlinked. OpenWorks IT support unlocks your account after checking it\'s really you.'),
          const SizedBox(height: 12),
          TextField(controller: password, obscureText: true, autofocus: true, decoration: const InputDecoration(labelText: 'Your password')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Lock my account')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final state = AppScope.of(context);
    try {
      await api.lockAccount(api.me?.getStringValue('email') ?? '', password.text);
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
      await state.signOut();
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = AppScope.api(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Your devices')),
      body: Loader<({List<LinkedDevice> devices, bool required})>(
        key: _key,
        load: api.myDevices,
        builder: (context, d, _) => ListView(padding: const EdgeInsets.fromLTRB(16, 10, 16, 28), children: [
          Text(
              d.required
                  ? 'You can sign in only on these. A new phone or browser is linked with a code we email you.'
                  : 'This server can\'t send email yet, so devices aren\'t linked: you sign in with your password and authenticator code anywhere.',
              style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
          const SizedBox(height: 10),
          if (d.devices.isEmpty) Text('No linked devices.', style: TextStyle(color: context.sc.ink2)),
          for (final dev in d.devices)
            Card(
              child: ListTile(
                leading: Icon(dev.platform == 'web' ? Icons.laptop : Icons.smartphone),
                title: Text(dev.current ? '${dev.name} (this one)' : dev.name),
                subtitle: Text([
                  if (dev.lastUsedAt != null) 'last used ${relTime(dev.lastUsedAt)}',
                  if (dev.linkedAt != null) 'linked ${relTime(dev.linkedAt)}',
                  if (dev.lastIp.isNotEmpty) 'from ${dev.lastIp}',
                ].join(' · ')),
                trailing: IconButton(tooltip: 'Remove', icon: const Icon(Icons.delete_outline), onPressed: () => _remove(dev)),
              ),
            ),
          const SizedBox(height: 20),
          Text('Lost or stolen phone?', style: context.tt.titleMedium),
          const SizedBox(height: 4),
          Text('Lock your account at once. You can also do this from the sign-in screen on any device.',
              style: TextStyle(color: context.sc.ink2)),
          const SizedBox(height: 8),
          OutlinedButton.icon(onPressed: _lock, icon: const Icon(Icons.lock_outline), label: const Text('Lock my account')),
        ]),
      ),
    );
  }
}
