// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../content/privacy_notice.dart';
import '../theme.dart';

class PrivacyNoticeScreen extends StatelessWidget {
  const PrivacyNoticeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(22, 32, 22, 16),
              children: [
                Icon(Icons.lock_outline, size: 34, color: context.cs.primary),
                const SizedBox(height: 10),
                Text(privacyNoticeTitle, style: context.tt.headlineSmall),
                const SizedBox(height: 4),
                Text('Please read this before you start.', style: TextStyle(color: context.sc.ink2)),
                const SizedBox(height: 18),
                for (final (heading, body) in privacyNoticeSections) ...[
                  Text(heading, style: context.tt.titleMedium),
                  const SizedBox(height: 4),
                  Text(body, style: context.tt.bodyMedium?.copyWith(height: 1.45)),
                  const SizedBox(height: 16),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 18),
            child: FilledButton(
              onPressed: () => AppScope.of(context).acknowledgePrivacy(),
              child: const Text('I understand'),
            ),
          ),
        ]),
      ),
    );
  }
}
