// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_zxing/flutter_zxing.dart';

/// The native app (Android now; iPhone once it is built) can scan.
bool get canScanInvites => !kIsWeb;

/// Opens the camera and returns the first QR code's text, or null if cancelled.
Future<String?> scanInviteCode(BuildContext context) =>
    Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const _ScanScreen()));

class _ScanScreen extends StatefulWidget {
  const _ScanScreen();
  @override
  State<_ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<_ScanScreen> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan your invite')),
      body: Stack(fit: StackFit.expand, children: [
        ReaderWidget(
          showGallery: false,
          showToggleCamera: false,
          cropPercent: 0.7,
          onScan: (code) {
            final text = code.text;
            if (_done || !code.isValid || text == null || text.isEmpty) return;
            _done = true;
            Navigator.of(context).pop(text);
          },
        ),
        Positioned(
          left: 24,
          right: 24,
          bottom: 96,
          child: DecoratedBox(
            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Point the camera at the QR code from your psychologist.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
