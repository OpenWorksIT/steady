// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../services/api.dart';
import '../theme.dart';
import '../widgets.dart';

/// The invite QR code and code, for the patient to scan or type.
Future<void> showInviteCode(BuildContext context, String serverUrl, String code, DateTime expires, {String? forClinician}) {
  return showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(forClinician == null ? 'Invite code' : 'Invite code for $forClinician'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Center(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                  child: QrImageView(
                    data: inviteLink(serverUrl, code),
                    size: 220,
                    backgroundColor: Colors.white,
                    semanticsLabel: 'Invite QR code',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Center(child: SelectableText(code, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: 2))),
              const SizedBox(height: 12),
              const Text('Android: your patient installs Steady, taps "Scan invite QR code" and points the camera here. '
                  'Steady connects to the practice and fills in the code.'),
              const SizedBox(height: 6),
              const Text('No app yet? They scan it with the phone\'s camera: Android phones get the download, '
                  'iPhones open Steady in the browser, ready to join.'),
              const SizedBox(height: 6),
              Text('Or they type the code. It works once and expires on ${expires.day}/${expires.month}/${expires.year}.',
                  style: TextStyle(color: context.sc.ink2)),
            ]),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: code));
                Navigator.pop(c);
                showSnack(context, 'Code copied');
              },
              child: const Text('Copy'),
            ),
            FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Done')),
          ],
        ),
      );
}
