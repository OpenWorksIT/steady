// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../services/api.dart';
import '../theme.dart';
import '../widgets.dart';

/// Change your own email address: your password and the new address, then the 6-digit code
/// sent to that address (so nobody can move an account to an address they don't read). The old
/// address is told.
class ChangeEmailScreen extends StatefulWidget {
  const ChangeEmailScreen({super.key});
  @override
  State<ChangeEmailScreen> createState() => _ChangeEmailScreenState();
}

class _ChangeEmailScreenState extends State<ChangeEmailScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  String? _sentTo;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _error = null);
    if (!_email.text.contains('@')) return setState(() => _error = 'Enter your new email address.');
    try {
      final to = await AppScope.of(context).api.emailChangeStart(_email.text, _password.text);
      if (!mounted) return;
      setState(() {
        _sentTo = to;
        _password.clear();
      });
    } catch (e) {
      setState(() => _error = errorText(e));
    }
  }

  Future<void> _finish() async {
    setState(() => _error = null);
    final state = AppScope.of(context);
    try {
      await state.api.emailChangeFinish(_code.text);
      if (!mounted) return;
      Navigator.of(context).pop();
      showSnack(context, 'Email changed to ${state.api.me?.getStringValue('email') ?? _email.text.trim()}.');
      state.changed();
    } catch (e) {
      setState(() => _error = errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final now = state.api.me?.getStringValue('email') ?? '';
    final staff = state.api.isStaff;
    return Scaffold(
      appBar: AppBar(title: const Text('Change email')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 24, 22, 24),
          children: [
            if (now.isNotEmpty) Text('Now: $now', style: TextStyle(color: context.sc.ink2)),
            const SizedBox(height: 6),
            Text(
                staff
                    ? 'Sign-in codes and notices about your account go to this address.'
                        '${state.config.communityUrl.isNotEmpty ? ' If you use the Community, ask OpenWorks IT to add the new address to your practice\'s list, or the Community won\'t let you in.' : ''}'
                    : 'Password-reset codes and messages about your account go to this address.',
                style: TextStyle(color: context.sc.ink2)),
            const SizedBox(height: 18),
            if (_sentTo == null) ...[
              AutofillGroup(
                child: Column(children: [
                  TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    decoration: const InputDecoration(labelText: 'New email address'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    decoration: const InputDecoration(labelText: 'Current password'),
                    onSubmitted: (_) => _send(),
                  ),
                ]),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: TextStyle(color: context.cs.error)),
              ],
              const SizedBox(height: 16),
              BusyButton(label: 'Email me a code', onPressed: _send),
            ] else ...[
              Text('We emailed a 6-digit code to $_sentTo. It works for 15 minutes. Check spam too.'),
              const SizedBox(height: 12),
              TextField(
                controller: _code,
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                decoration: const InputDecoration(labelText: 'Code from the email'),
                onSubmitted: (_) => _finish(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: TextStyle(color: context.cs.error)),
              ],
              const SizedBox(height: 16),
              BusyButton(label: 'Change email', onPressed: _finish),
              TextButton(
                onPressed: () => setState(() {
                  _sentTo = null;
                  _code.clear();
                  _error = null;
                }),
                child: const Text('Use a different address'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
