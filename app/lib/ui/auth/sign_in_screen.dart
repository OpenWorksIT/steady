// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../services/api.dart';
import '../theme.dart';
import '../widgets.dart';
import 'invite_flow.dart';
import 'join_screen.dart';
import 'server_screen.dart';
import '../brand.dart';

class SignInScreen extends StatefulWidget {
  final String? message;
  const SignInScreen({this.message, super.key});
  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  bool _needCode = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // opened from an invite link on the web: go straight to joining
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = AppScope.of(context);
      final code = state.pendingInvite;
      if (code == null) return;
      state.pendingInvite = null;
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => JoinScreen(initialCode: code)));
    });
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    setState(() => _error = null);
    final state = AppScope.of(context);
    try {
      await state.api.signIn(_email.text, _password.text, code: _needCode ? _code.text : null);
      await state.signedInNow();
    } on TwoStepNeeded {
      setState(() => _needCode = true);
    } catch (e) {
      setState(() => _error = errorText(e).contains('Failed to authenticate') ? 'That email and password didn\'t match.' : errorText(e));
    }
  }

  // Resets are done by people at the practice, not by email: no reset link can be
  // intercepted, and nobody needs an inbox they share with others.
  Future<void> _forgot() => showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Forgot your password?'),
          content: const Text('Ask your psychologist or the practice to reset it. They give you a temporary password, '
              'and you choose a new one when you sign in.\n\n'
              'Psychologists: the practice\'s master clinician resets yours.'),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final cfg = AppScope.of(context).config;
    return Scaffold(
      body: BrandBackdrop(
        child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 40, 22, 24),
          children: [
            PracticeHeader(name: cfg.practiceName),
            const SizedBox(height: 30),
            Text('Steady', style: context.tt.headlineSmall),
            Text('Your between-session check-ins', style: context.tt.bodyLarge?.copyWith(color: context.sc.ink2)),
            const SizedBox(height: 20),
            if (widget.message != null) ...[
              Text(widget.message!, style: TextStyle(color: context.sc.warn)),
              const SizedBox(height: 12),
            ],
            AutofillGroup(
              child: Column(children: [
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  decoration: const InputDecoration(labelText: 'Password'),
                  onSubmitted: (_) => _signIn(),
                ),
                if (_needCode) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _code,
                    autofocus: true,
                    keyboardType: TextInputType.visiblePassword,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    decoration: const InputDecoration(
                      labelText: 'Code from your authenticator app',
                      helperText: 'Lost your phone? Type one of your recovery codes instead.',
                    ),
                    onSubmitted: (_) => _signIn(),
                  ),
                ],
              ]),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: TextStyle(color: context.cs.error)),
            ],
            const SizedBox(height: 16),
            BusyButton(label: 'Sign in', onPressed: _signIn),
            TextButton(onPressed: _forgot, child: const Text('Forgot password')),
            const SizedBox(height: 20),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('New here?', style: context.tt.titleMedium),
                  const SizedBox(height: 4),
                  Text('Your psychologist will give you an invite QR code or code.', style: TextStyle(color: context.sc.ink2)),
                  const SizedBox(height: 12),
                  if (canScanInvites) ...[const ScanInviteButton(), const SizedBox(height: 8)],
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const JoinScreen())),
                    child: const Text('I have an invite code'),
                  ),
                ]),
              ),
            ),
            if (!AppScope.api(context).serverLocked) ...[
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  child: Text('Server: ${AppScope.api(context).serverUrl}',
                      style: context.tt.bodySmall?.copyWith(color: context.sc.ink3), overflow: TextOverflow.ellipsis),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ServerScreen(firstRun: false))),
                  child: const Text('Change'),
                ),
              ]),
            ],
          ],
        ),
      ),
      ),
    );
  }
}
