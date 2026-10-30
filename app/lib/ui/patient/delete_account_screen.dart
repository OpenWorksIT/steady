// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A patient asks for their Steady account to be deleted. The practice carries it out: South
// African law (HPCSA Booklet 9) requires it to keep clinical records, so it first copies what
// belongs in the patient's clinical file. See server/pb_hooks/lib/deletion.js.
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../services/api.dart';
import '../theme.dart';
import '../widgets.dart';

class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({super.key});
  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  final _password = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _ask() async {
    setState(() => _error = null);
    if (_password.text.isEmpty) return setState(() => _error = 'Enter your password.');
    try {
      await AppScope.api(context).requestAccountDeletion(_password.text);
      if (mounted) setState(() {});
    } catch (e) {
      setState(() => _error = errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final asked = AppScope.api(context).deletionRequestedAt;
    final ink2 = TextStyle(color: context.sc.ink2);
    return Scaffold(
      appBar: AppBar(title: const Text('Delete my account')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(22, 20, 22, 28), children: [
          if (asked != null) ...[
            Icon(Icons.mark_email_read_outlined, size: 40, color: context.cs.primary),
            const SizedBox(height: 12),
            Text('We\'ve received your request', style: context.tt.headlineSmall),
            const SizedBox(height: 8),
            Text('You asked on ${relTime(asked)}. Your practice will delete your Steady account within 30 days, and '
                'you\'ll get an email when it\'s done. Until then you can still use Steady.', style: ink2),
            const SizedBox(height: 12),
            Text('If you change your mind, tell your psychologist.', style: ink2),
          ] else ...[
            Text('What happens', style: context.tt.titleMedium),
            const SizedBox(height: 6),
            Text('Your request goes to your practice. Within 30 days they delete your Steady account and everything '
                'Steady holds about you: your check-ins, answers, notes and watch data. You\'ll get an email when it\'s done.',
                style: ink2),
            const SizedBox(height: 16),
            Text('Why your practice does it', style: context.tt.titleMedium),
            const SizedBox(height: 6),
            Text('South African law requires your psychologist to keep your clinical records: for at least six years '
                'after your last contact, until your 21st birthday if you\'re under 18, and for life in some cases '
                '(HPCSA Booklet 9). So your practice first copies what belongs in your clinical file, then deletes your '
                'Steady account. A log of who opened your record, and when, is also kept.', style: ink2),
            const SizedBox(height: 16),
            Text('If you\'re finding things hard right now, please talk to your psychologist first, or use the crisis '
                'numbers in the app.', style: ink2),
            const SizedBox(height: 20),
            TextField(
              controller: _password,
              obscureText: true,
              autofillHints: const [AutofillHints.password],
              decoration: const InputDecoration(labelText: 'Your password', helperText: 'So we know it\'s really you.'),
              onSubmitted: (_) => _ask(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: TextStyle(color: context.cs.error)),
            ],
            const SizedBox(height: 16),
            BusyButton(label: 'Ask to delete my account', onPressed: _ask),
          ],
        ]),
      ),
    );
  }
}
