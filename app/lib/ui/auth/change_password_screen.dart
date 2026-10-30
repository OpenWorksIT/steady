// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../services/api.dart';
import '../brand.dart';
import '../theme.dart';
import '../widgets.dart';

/// Choose a new password. [forced]: after a reset, the temporary password does nothing else.
class ChangePasswordScreen extends StatefulWidget {
  final bool forced;
  const ChangePasswordScreen({this.forced = false, super.key});
  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _again = TextEditingController();
  final _code = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _again.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _error = null);
    if (_next.text.length < 10) return setState(() => _error = 'Choose a password of at least 10 characters.');
    if (_next.text != _again.text) return setState(() => _error = "The two new passwords aren't the same.");
    final state = AppScope.of(context);
    try {
      await state.api.changePassword(_current.text, _next.text, emailCode: state.api.emailCodeNeeded ? _code.text : null);
      if (!mounted) return;
      if (!widget.forced) {
        Navigator.of(context).pop();
        showSnack(context, 'Password changed. Other phones and browsers are signed out.');
      }
      state.changed();
    } catch (e) {
      setState(() => _error = errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Scaffold(
      appBar: widget.forced ? null : AppBar(title: const Text('Change password')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 32, 22, 24),
          children: [
            if (widget.forced) ...[
              PracticeHeader(name: state.config.practiceName),
              const SizedBox(height: 24),
              Text('Choose your own password', style: context.tt.headlineSmall),
              const SizedBox(height: 6),
              Text('You signed in with a temporary password. Choose a new one that only you know before you carry on.',
                  style: TextStyle(color: context.sc.ink2)),
              if (state.api.emailCodeNeeded) ...[
                const SizedBox(height: 8),
                Text('We also emailed you a 6-digit code. Only you can see it, so only you can finish the reset.',
                    style: TextStyle(color: context.sc.ink2)),
              ],
              const SizedBox(height: 18),
            ],
            AutofillGroup(
              child: Column(children: [
                TextField(
                  controller: _current,
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  decoration: InputDecoration(labelText: widget.forced ? 'Temporary password' : 'Current password'),
                ),
                if (state.api.emailCodeNeeded) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _code,
                    keyboardType: TextInputType.number,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    decoration: const InputDecoration(labelText: 'Code from the email', helperText: 'Check spam too. It works for 24 hours.'),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: _next,
                  obscureText: true,
                  autofillHints: const [AutofillHints.newPassword],
                  decoration: const InputDecoration(labelText: 'New password', helperText: 'At least 10 characters. A short sentence works well.'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _again,
                  obscureText: true,
                  autofillHints: const [AutofillHints.newPassword],
                  decoration: const InputDecoration(labelText: 'New password again'),
                  onSubmitted: (_) => _save(),
                ),
              ]),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: TextStyle(color: context.cs.error)),
            ],
            const SizedBox(height: 16),
            BusyButton(label: 'Save password', onPressed: _save),
            if (widget.forced) TextButton(onPressed: () => state.signOut(), child: const Text('Sign out')),
          ],
        ),
      ),
    );
  }
}
