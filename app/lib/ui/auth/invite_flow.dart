// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../services/api.dart';
import '../widgets.dart';
import 'invite_scan.dart';
import 'join_screen.dart';

export 'invite_scan.dart' show canScanInvites;

/// Scan an invite QR: connect to the server it names (after asking), then open the join
/// form with the code filled in.
Future<void> scanAndJoin(BuildContext context) async {
  final state = AppScope.of(context);
  final nav = Navigator.of(context);
  final raw = await scanInviteCode(context);
  if (raw == null || !context.mounted) return;
  final inv = parseInviteLink(raw);
  if (inv == null) {
    showSnack(context, "That QR code isn't a Steady invite. Ask your psychologist to show it again.");
    return;
  }
  final api = state.api;
  final current = normaliseServerUrl(api.serverUrl);
  if (inv.server != current) {
    if (api.serverLocked) {
      showSnack(context, 'This invite is for a different practice server. Ask your psychologist for a new code.');
      return;
    }
    final host = Uri.parse(inv.server).host;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Connect to your practice?'),
        content: Text('This invite connects Steady to $host. Only continue if your psychologist gave you this code.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Connect')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await state.setServer(inv.server);
    } catch (e) {
      if (context.mounted) showSnack(context, errorText(e));
      return;
    }
  }
  await nav.push(MaterialPageRoute(builder: (_) => JoinScreen(initialCode: inv.code)));
}

/// "Scan invite QR" button, shown only where the app can scan.
class ScanInviteButton extends StatelessWidget {
  final bool primary;
  const ScanInviteButton({this.primary = true, super.key});

  @override
  Widget build(BuildContext context) {
    if (!canScanInvites) return const SizedBox.shrink();
    const icon = Icon(Icons.qr_code_scanner);
    const label = Text('Scan invite QR code');
    return primary
        ? FilledButton.icon(onPressed: () => scanAndJoin(context), icon: icon, label: label)
        : OutlinedButton.icon(onPressed: () => scanAndJoin(context), icon: icon, label: label);
  }
}
