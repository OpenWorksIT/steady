// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Settings, for everyone: a page of its own behind the gear (it was a pop-up), so each screen it
// opens comes back to it. Practice staff also find the practice here (Settings > Practice).
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/api.dart';
import '../services/push.dart';
import '../wearable/wearable_sync.dart';
import '../build_info.dart';
import 'auth/change_email_screen.dart';
import 'auth/change_password_screen.dart';
import 'auth/devices_screen.dart';
import 'auth/screen_lock.dart';
import 'auth/server_screen.dart';
import 'auth/two_step_screen.dart';
import 'clinician/server_updates_screen.dart';
import 'update_notice.dart';
import 'source_link.dart';
import 'patient/delete_account_screen.dart';
import 'theme.dart';
import 'clinician/patient_care.dart';
import 'practice/audit_screen.dart' show ServerHealthScreen;
import 'practice/practice_screen.dart';

/// Opens Settings. Patients get the calm page transition from their theme.
Future<void> openSettings(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));

/// The gear on each role's first screen.
class SettingsButton extends StatelessWidget {
  const SettingsButton({super.key});
  @override
  Widget build(BuildContext context) =>
      IconButton(tooltip: 'Settings', icon: const Icon(Icons.settings_outlined), onPressed: () => openSettings(context));
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final android = !kIsWeb && _isAndroid;
    final practice = practiceItems(state.api);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(state.api.myName, style: context.tt.titleLarge),
            Text(state.api.me?.getStringValue('email') ?? '', style: TextStyle(color: context.sc.ink2)),
            // practice staff: the library and the practice's own business, out of the bottom bar
            if (practice.isNotEmpty) ...[
              const SizedBox(height: 8),
              SettingsLink(
                icon: Icons.apartment_outlined,
                title: 'Practice',
                subtitle: practiceSummary(practice),
                open: () => const PracticeScreen(),
              ),
            ],
            const SizedBox(height: 18),
            Text('Notifications', style: context.tt.titleMedium),
            const SizedBox(height: 4),
            Text(pushStatusText(on: state.pushEnabled), style: TextStyle(color: context.sc.ink2)),
            // a copy built without Firebase can't get notifications on Android, however often it tries
            if (!state.pushEnabled && !kIsWeb && (!android || kAndroidPushBuiltIn)) ...[
              const SizedBox(height: 8),
              OutlinedButton(onPressed: () => state.enablePush(), child: const Text('Try again')),
            ],
            if (state.isPatient && state.api.wearableConnected) ...[
              const SizedBox(height: 18),
              Text('Watch data', style: context.tt.titleMedium),
              const SizedBox(height: 4),
              Text('Your daily watch summaries are shared with your psychologist.', style: TextStyle(color: context.sc.ink2)),
              TextButton(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  try {
                    await WearableSync.instance.disconnect(state.api);
                    state.changed();
                    messenger.showSnackBar(const SnackBar(content: Text('Watch data is no longer shared. What was already shared stays in your record.')));
                  } catch (e) {
                    messenger.showSnackBar(SnackBar(content: Text(errorText(e))));
                  }
                },
                child: const Text('Stop sharing watch data'),
              ),
            ],
            if (state.isPatient) const _CareTeam(),
            if (state.isClinician) ...[
              const SizedBox(height: 12),
              Text('Your patients', style: context.tt.titleMedium),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.inventory_2_outlined),
                title: const Text('Archived patients'),
                subtitle: const Text('People you\'re no longer seeing; bring someone back'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ArchivedPatientsScreen())),
              ),
            ],
            const SizedBox(height: 12),
            Text('Your account', style: context.tt.titleMedium),
            // patients on a phone: lock Steady with the phone's screen lock, off unless they turn it on
            if (state.isPatient && !kIsWeb) const _LockSwitch(),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.password),
              title: const Text('Change password'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ChangePasswordScreen())),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.alternate_email),
              title: const Text('Change email'),
              subtitle: Text(state.api.me?.getStringValue('email') ?? ''),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ChangeEmailScreen())),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(state.api.twoStepOn ? Icons.verified_user : Icons.verified_user_outlined),
              title: const Text('Two-step sign-in'),
              subtitle: Text(state.api.twoStepOn
                  ? 'On: signing in needs a code from your authenticator app'
                  : 'Off: add a code from an authenticator app to signing in'),
              trailing: state.api.twoStepOn ? null : const Icon(Icons.chevron_right),
              onTap: state.api.twoStepOn
                  ? null
                  : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TwoStepSetupScreen())),
            ),
            if (state.isPatient)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_remove_outlined),
                title: const Text('Delete my account'),
                subtitle: Text(state.api.deletionRequestedAt == null
                    ? 'Ask your practice to delete your account and your Steady data'
                    : 'You\'ve asked; your practice will email you when it\'s done'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DeleteAccountScreen())),
              ),
            if (state.api.isStaff)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.devices_outlined),
                title: const Text('Your devices'),
                subtitle: const Text('Where you can sign in; lock your account if a phone is lost'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DevicesScreen())),
              ),
            if (state.api.canUpdate) ...[
              const SizedBox(height: 16),
              const UpdateControls(),
            ] else if (state.api.canSeeHealth) ...[
              // the practice admin sees the server's health but doesn't start updates
              const SizedBox(height: 12),
              Text('The server', style: context.tt.titleMedium),
              SettingsLink(
                icon: Icons.monitor_heart_outlined,
                title: 'Server health',
                subtitle: 'How the practice\'s server is coping',
                open: () => const ServerHealthScreen(),
              ),
            ],
            if (appUpdateAvailable(state)) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                icon: const Icon(Icons.download),
                onPressed: () => downloadAppUpdate(context),
                label: const Text('Download the new version of Steady'),
              ),
            ],
            const SizedBox(height: 20),
            OutlinedButton.icon(
              icon: const Icon(Icons.logout),
              onPressed: () async {
                // answers kept on this phone (the practice couldn't be reached) go with the sign-out
                final waiting = state.api.outbox.waiting;
                if (waiting > 0) {
                  final go = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: Text(waiting == 1 ? '1 answer hasn\'t been sent' : '$waiting answers haven\'t been sent'),
                      content: const Text('Steady couldn\'t reach the practice yet. If you sign out now, they\'re deleted from this phone '
                          'and your psychologist won\'t see them.'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Stay signed in')),
                        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Sign out and delete them')),
                      ],
                    ),
                  );
                  if (go != true || !context.mounted) return;
                }
                // close every screen first: the one underneath becomes the sign-in screen
                Navigator.of(context).popUntil((r) => r.isFirst);
                await state.signOut();
              },
              label: const Text('Sign out'),
            ),
            const SizedBox(height: 4),
            Text('Signs you out on all your devices.',
                textAlign: TextAlign.center, style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: Text('Server: ${state.api.serverUrl}',
                    style: context.tt.bodySmall?.copyWith(color: context.sc.ink3), overflow: TextOverflow.ellipsis),
              ),
              if (!state.api.serverLocked && !kIsWeb)
                TextButton(
                  onPressed: () async {
                    final nav = Navigator.of(context);
                    await nav.push(MaterialPageRoute(builder: (_) => const ServerScreen(firstRun: false)));
                    // another server signs you out: back to the first screen, which asks you to sign in
                    if (!state.signedIn) nav.popUntil((r) => r.isFirst);
                  },
                  child: const Text('Change'),
                ),
            ]),
            Text('Steady $thisAppVersion'
                '${appUpdateAvailable(state) ? ' · ${versionLabel(state.config.appVersion, state.config.appBuild)} available' : ''}',
                style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
            const SourceLink(),
          ]),
        ),
      ),
    );
  }
}

bool get _isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Patients: who at the practice can see what they send.
class _CareTeam extends StatelessWidget {
  const _CareTeam();
  @override
  Widget build(BuildContext context) {
    final api = AppScope.api(context);
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: FutureBuilder<({String clinician, List<String> shared})>(
        future: api.careTeam(),
        builder: (context, snap) {
          final t = snap.data;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Who sees what you send', style: context.tt.titleMedium),
            const SizedBox(height: 4),
            Text(
              t == null
                  ? (snap.hasError ? errorText(snap.error!) : '...')
                  : [
                      if (t.clinician.isNotEmpty) 'Your psychologist, ${t.clinician}.',
                      if (t.shared.isNotEmpty) 'Also shared with ${t.shared.join(', ')}, who can read it but not change anything.',
                      if (t.clinician.isEmpty && t.shared.isEmpty) 'Nobody yet.',
                    ].join(' '),
              style: TextStyle(color: context.sc.ink2),
            ),
          ]);
        },
      ),
    );
  }
}

/// Patients on a phone: "Lock Steady" (ui/auth/screen_lock.dart). Kept on this phone only.
class _LockSwitch extends StatefulWidget {
  const _LockSwitch();
  @override
  State<_LockSwitch> createState() => _LockSwitchState();
}

class _LockSwitchState extends State<_LockSwitch> {
  bool _noLock = false;
  bool _busy = false;

  Future<void> _set(String id, bool on) async {
    if (!on) return PatientLock.instance.set(id, false);
    setState(() => _busy = true);
    final has = await phoneHasScreenLock();
    // asked once now, so the patient knows it works before Steady relies on it
    final ok = has && await unlockWithScreenLock('Turn on Lock Steady');
    if (!mounted) return;
    setState(() {
      _noLock = !has;
      _busy = false;
    });
    if (ok) await PatientLock.instance.set(id, true);
  }

  @override
  Widget build(BuildContext context) {
    final id = AppScope.api(context).myId;
    PatientLock.instance.load(id);
    return ListenableBuilder(
      listenable: PatientLock.instance,
      builder: (context, _) {
        final on = PatientLock.instance.isOn(id) ?? false;
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.lock_outline),
          title: const Text('Lock Steady'),
          subtitle: Text(_noLock
              ? 'This phone has no screen lock. Set a PIN, pattern, password or fingerprint in the phone\'s settings first.'
              : on
                  ? 'On: Steady asks for your phone\'s screen lock when you open it, and after two minutes away'
                  : 'Ask for your phone\'s screen lock (fingerprint, face, PIN or pattern) when you open Steady'),
          value: on,
          onChanged: _busy ? null : (v) => _set(id, v),
        );
      },
    );
  }
}

/// A row in Settings (and Settings > Practice) that opens a screen; back comes back here.
class SettingsLink extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;
  final Widget Function() open;
  const SettingsLink({required this.icon, required this.title, required this.subtitle, required this.open, super.key});
  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => open())),
      );
}
