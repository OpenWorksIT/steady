// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Before going on, a patient answers what the practice needs from them:
//   - the practice changed its consent statement after they agreed to an earlier one (for example
//     its own statement replacing Steady's draft): they read the new one and agree;
//   - they joined before Steady asked whether the practice may contact them about what they share
//     (contact_consent.dart): they answer that, once.
// Both sit on this one screen, the contact tick box right above the button. The other ways out
// are signing out and talking to their clinician; the crisis numbers stay on the screen.
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../services/api.dart';
import '../theme.dart';
import '../widgets.dart';
import 'contact_consent.dart';

class ConsentAgainScreen extends StatefulWidget {
  const ConsentAgainScreen({super.key});
  @override
  State<ConsentAgainScreen> createState() => _ConsentAgainScreenState();
}

class _ConsentAgainScreenState extends State<ConsentAgainScreen> {
  bool _agree = false;
  bool? _contact;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // an answer they gave before stays as it was; not asked yet: ticked to start with
    _contact ??= AppScope.of(context).api.myContactConsent != 'no';
  }

  Future<void> _continue() async {
    final state = AppScope.of(context);
    setState(() => _error = null);
    try {
      if (state.needsConsentAgain) {
        await state.api.setConsent('consent', state.config.consentVersion, contact: state.config.contactAsk ? _contact : null);
      } else {
        await state.api.setConsent('contact', contactConsentVersion, accepted: _contact ?? true);
      }
      state.consentRecorded();
    } catch (e) {
      // only the contact question: it can wait for a signal, and never keeps them from Steady
      if (!state.needsConsentAgain) {
        state.deferContactAnswer();
        return;
      }
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final cfg = state.config;
    final statement = state.needsConsentAgain;
    return Scaffold(
      appBar: AppBar(title: const Text('Before you go on')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(22, 12, 22, 28), children: [
          if (statement) ...[
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
          ] else
            Text('One question from ${cfg.practiceName} before you go on.', style: context.tt.bodyLarge),
          if (cfg.contactAsk) ...[
            const SizedBox(height: 8),
            ContactConsentTile(practiceName: cfg.practiceName, value: _contact ?? true, onChanged: (v) => setState(() => _contact = v)),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: context.cs.error)),
          ],
          const SizedBox(height: 12),
          BusyButton(
            label: statement ? 'Agree and continue' : 'Continue',
            onPressed: !statement || _agree ? _continue : null,
          ),
          if (statement) ...[
            const SizedBox(height: 16),
            Text("If you don't agree, talk to your clinician about it. Until then you can sign out.",
                style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: () => state.signOut(), child: const Text('Sign out')),
            ),
          ],
          const SizedBox(height: 24),
          const CrisisFooter(),
        ]),
      ),
    );
  }
}
