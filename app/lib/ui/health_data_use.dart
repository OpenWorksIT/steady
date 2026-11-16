// SPDX-License-Identifier: AGPL-3.0-or-later
//
// What Health Connect shows when someone asks why Steady reads their data: its permission
// screen's privacy link, and Android 14's "permission usage". MainActivity (app/scripts/
// patch_android.py) passes those on over the "steady/healthdata" channel, and this page opens
// over whatever screen is up, before any sign-in. It says what each data type is for, where it
// shows and how it helps, as the Play Console declarations do, then the privacy notice.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../content/privacy_notice.dart';
import 'source_link.dart';
import 'theme.dart';

/// Each data type Steady reads from Health Connect: what, where it shows and why it helps.
const healthDataUses = <(String, String)>[
  (
    'Heart rate',
    'Your lowest, average and highest heart rate for each day, and your resting heart rate. You see it in Steady '
        '(tap the watch card on your home screen). Your psychologist sees it in your record and in RADR, which compares '
        'your resting heart rate with your own usual, so they notice a change between sessions and can check in sooner.',
  ),
  (
    'Sleep',
    'How long you slept, when you fell asleep and woke, and your sleep stages. You see it in Steady; your psychologist '
        'sees it in your record and in RADR, which notices when your sleep is shorter, longer or later than usual. '
        'Changes in sleep are often an early sign that someone is struggling.',
  ),
  (
    'Steps',
    'Your steps for each day. You see them in Steady; your psychologist sees them in your record and in RADR, which '
        'notices when you are less active than usual, so they can follow up.',
  ),
  (
    'Blood oxygen',
    'Your average and lowest blood oxygen for each day, if your watch measures it. You and your psychologist see it '
        'next to your sleep in the daily charts, so they can talk it through with you and suggest seeing your doctor if '
        'it is low.',
  ),
];

class HealthDataUseScreen extends StatelessWidget {
  const HealthDataUseScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Steady and your health data')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          children: [
            Text(
              'Steady connects you with your own psychologist between sessions. If you choose to connect your watch, '
              'Steady reads what it saved in Health Connect and shares a daily summary with your psychologist, so they '
              'can follow how you are doing and get in touch sooner if things change. It is optional, and you can stop '
              'at any time.',
              style: context.tt.bodyLarge,
            ),
            const SizedBox(height: 16),
            for (final (title, body) in healthDataUses) ...[
              Text(title, style: context.tt.titleMedium),
              const SizedBox(height: 4),
              Text(body, style: context.tt.bodyMedium?.copyWith(height: 1.45)),
              const SizedBox(height: 14),
            ],
            Text('What Steady doesn\'t do', style: context.tt.titleMedium),
            const SizedBox(height: 4),
            Text(
              'It only reads, never writes to Health Connect, and never reads further back than 30 days. Only daily '
              'totals and averages leave your phone, and only your psychologist (and a colleague they share your record '
              'with) sees them. It never uses them for advertising and never sells them. It doesn\'t measure anything '
              'itself. To stop, tap "Stop sharing watch data" in Settings in Steady, or remove Steady\'s access in Health '
              'Connect.',
              style: context.tt.bodyMedium?.copyWith(height: 1.45),
            ),
            const SizedBox(height: 14),
            Text(kNotMedicalDevice, style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
            const SizedBox(height: 24),
            Text(privacyNoticeTitle, style: context.tt.titleLarge),
            const SizedBox(height: 8),
            for (final (heading, body) in privacyNoticeSections) ...[
              Text(heading, style: context.tt.titleMedium),
              const SizedBox(height: 4),
              Text(body, style: context.tt.bodyMedium?.copyWith(height: 1.45)),
              const SizedBox(height: 14),
            ],
          ],
        ),
      ),
    );
  }
}

/// Opens [HealthDataUseScreen] when Health Connect started Steady to ask why (or does so while
/// it's running). Android only.
class HealthDataUse {
  static const _channel = MethodChannel('steady/healthdata');

  static void listen(GlobalKey<NavigatorState> navigatorKey) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'show') _open(navigatorKey);
    });
    _channel.invokeMethod<bool>('opened').then((asked) {
      if (asked == true) _open(navigatorKey);
    }).catchError((_) {});
  }

  static void _open(GlobalKey<NavigatorState> navigatorKey, [int tries = 0]) {
    WidgetsBinding.instance.ensureVisualUpdate();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final nav = navigatorKey.currentState;
      if (nav == null) {
        if (tries < 20) _open(navigatorKey, tries + 1);
        return;
      }
      nav.push(MaterialPageRoute(builder: (_) => const HealthDataUseScreen()));
    });
  }
}
