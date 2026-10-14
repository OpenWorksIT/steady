// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/push.dart';
import 'theme.dart';
import 'widgets.dart';

Future<void> showSettingsSheet(BuildContext context) => showModalBottomSheet(
      context: context,
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
    final android = !kIsWeb && Platform.isAndroid;
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
          if (!state.pushEnabled) ...[
            const SizedBox(height: 8),
            OutlinedButton(onPressed: () => state.enablePush(), child: const Text('Try again')),
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
          Text('Steady is free software (AGPL-3.0) by OpenWorks IT.', style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
        ]),
      ),
    );
  }
}
