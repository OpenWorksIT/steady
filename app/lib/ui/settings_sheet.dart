// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/api.dart';
import '../services/push.dart';
import '../wearable/wearable_sync.dart';
import '../build_info.dart';
import 'auth/change_password_screen.dart';
import 'auth/server_screen.dart';
import 'auth/two_step_screen.dart';
import 'clinician/server_updates_screen.dart';
import 'update_notice.dart';
import 'calm.dart';
import 'theme.dart';
import 'widgets.dart';
import 'clinician/feedback_inbox_screen.dart';

Future<void> showSettingsSheet(BuildContext context) => showModalBottomSheet(
      context: context,
      sheetAnimationStyle: calmSheetStyle(AppScope.of(context).isPatient),
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const _SettingsSheet(),
    );

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet();
  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  List<String> _distributors = const [];

  @override
  void initState() {
    super.initState();
    PushService.instance.distributors().then((d) {
      if (mounted) setState(() => _distributors = d);
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final android = !kIsWeb && _isAndroid;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(state.api.myName, style: context.tt.titleLarge),
          Text(state.api.me?.getStringValue('email') ?? '', style: TextStyle(color: context.sc.ink2)),
          const SizedBox(height: 18),
          Text('Notifications', style: context.tt.titleMedium),
          const SizedBox(height: 4),
          Text(
            state.pushEnabled
                ? 'On. Notifications never show names or answers, only that there is something new.'
                : kIsWeb
                    ? 'The web version can\'t send notifications. New items appear here while the page is open; install the app for alerts.'
                    : android
                    ? 'Off. On Android, Steady delivers notifications through a free app such as ntfy, so no data goes to Google. Install one, then choose it below.'
                    : 'Off. Allow notifications for Steady in your phone\'s settings.',
            style: TextStyle(color: context.sc.ink2),
          ),
          if (android && _distributors.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final d in _distributors)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.notifications_active_outlined),
                title: Text(d.split('.').last),
                subtitle: Text(d),
                onTap: () async {
                  await PushService.instance.useDistributor(d);
                  await state.enablePush();
                  if (context.mounted) showSnack(context, 'Notifications set up');
                },
              ),
          ],
          if (!state.pushEnabled && !kIsWeb) ...[
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
                Navigator.of(context).pop();
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
          const SizedBox(height: 12),
          Text('Your account', style: context.tt.titleMedium),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.password),
            title: const Text('Change password'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              final nav = Navigator.of(context);
              nav.pop();
              nav.push(MaterialPageRoute(builder: (_) => const ChangePasswordScreen()));
            },
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
                : () {
                    final nav = Navigator.of(context);
                    nav.pop();
                    nav.push(MaterialPageRoute(builder: (_) => const TwoStepSetupScreen()));
                  },
          ),
          if (state.api.canUpdate) ...[
            const SizedBox(height: 16),
            const UpdateControls(),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.feedback_outlined),
              title: const Text('Feedback'),
              subtitle: const Text('Love, dislikes and bugs sent from staff screens'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                final nav = Navigator.of(context);
                nav.pop();
                nav.push(MaterialPageRoute(builder: (_) => const FeedbackInboxScreen()));
              },
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
              Navigator.of(context).pop();
              await state.signOut();
            },
            label: const Text('Sign out'),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: Text('Server: ${state.api.serverUrl}',
                  style: context.tt.bodySmall?.copyWith(color: context.sc.ink3), overflow: TextOverflow.ellipsis),
            ),
            if (!state.api.serverLocked && !kIsWeb)
              TextButton(
                onPressed: () {
                  final nav = Navigator.of(context);
                  nav.pop();
                  nav.push(MaterialPageRoute(builder: (_) => const ServerScreen(firstRun: false)));
                },
                child: const Text('Change'),
              ),
          ]),
          Text('Steady ${kAppBuild.isEmpty ? '(development build)' : 'build $kAppBuild'}'
              '${appUpdateAvailable(state) ? ' · build ${state.config.appBuild} available' : ''}',
              style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
          Text('Steady is free software (AGPL-3.0) by OpenWorks IT.', style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
        ]),
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
