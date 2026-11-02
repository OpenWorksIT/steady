// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The practice changed its consent statement after this patient agreed to an earlier one (for
// example its own statement replacing Steady's draft): they read the new one and agree before
// going on. The other ways out are signing out and talking to their psychologist; the crisis
// numbers stay on the screen.
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../services/api.dart';
import '../theme.dart';
import '../widgets.dart';

class ConsentAgainScreen extends StatefulWidget {
  const ConsentAgainScreen({super.key});
  @override
  State<ConsentAgainScreen> createState() => _ConsentAgainScreenState();
}

class _ConsentAgainScreenState extends State<ConsentAgainScreen> {
  bool _agree = false;
  String? _error;

  Future<void> _continue() async {
    final state = AppScope.of(context);
    setState(() => _error = null);
    try {
      await state.api.setConsent('consent', state.config.consentVersion);
      state.consentRecorded();
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final cfg = state.config;
    return Scaffold(
      appBar: AppBar(title: const Text('Before you go on')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(22, 12, 22, 28), children: [
          Text('${cfg.practiceName} has changed how it explains its use of your information. '
              'Please read it, and agree to it to keep using Steady.',
              style: context.tt.bodyLarge),
          const SizedBox(height: 16),
          Card(
            child: Padding(padding: const EdgeInsets.all(16), child: SelectableText(cfg.consentText)),
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            value: _agree,
            onChanged: (v) => setState(() => _agree = v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            title: Text('I have read and agree to how ${cfg.practiceName} will use my information'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: context.cs.error)),
          ],
          const SizedBox(height: 12),
          BusyButton(label: 'Agree and continue', onPressed: _agree ? _continue : null),
          const SizedBox(height: 16),
          Text("If you don't agree, talk to your psychologist about it. Until then you can sign out.",
              style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: () => state.signOut(), child: const Text('Sign out')),
          ),
          const SizedBox(height: 24),
          const CrisisFooter(),
        ]),
      ),
    );
  }
}
