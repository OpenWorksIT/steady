// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets.dart';

class DoneScreen extends StatelessWidget {
  final String message;

  /// Kept on the phone to send later, rather than sent.
  final bool kept;
  const DoneScreen({required this.message, this.kept = false, super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(automaticallyImplyLeading: false),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
            children: [
              Center(
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(color: context.sc.calmSoft, shape: BoxShape.circle),
                  child: Icon(kept ? Icons.schedule_send_outlined : Icons.check, size: 36, color: context.sc.calm),
                ),
              ),
              const SizedBox(height: 16),
              Text('Thank you', textAlign: TextAlign.center, style: context.tt.headlineSmall),
              const SizedBox(height: 8),
              Text(message, textAlign: TextAlign.center, style: context.tt.bodyLarge?.copyWith(color: context.sc.ink2)),
              const SizedBox(height: 24),
              FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Back to home')),
              const SizedBox(height: 32),
              const CrisisFooter(),
            ],
          ),
        ),
      );
}
