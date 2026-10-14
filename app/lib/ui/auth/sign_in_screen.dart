// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../services/api.dart';
import '../theme.dart';
import '../widgets.dart';
import 'join_screen.dart';

class SignInScreen extends StatefulWidget {
  final String? message;
  const SignInScreen({this.message, super.key});
  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    setState(() => _error = null);
    final state = AppScope.of(context);
    try {
      await state.api.signIn(_email.text, _password.text);
      await state.signedInNow();
    } catch (e) {
      setState(() => _error = errorText(e).contains('Failed to authenticate') ? 'That email and password didn\'t match.' : errorText(e));
    }
  }

  Future<void> _forgot() async {
    if (_email.text.trim().isEmpty) {
      setState(() => _error = 'Enter your email first, then tap "Forgot password".');
      return;
    }
    try {
      await AppScope.api(context).requestPasswordReset(_email.text);
      if (mounted) showSnack(context, 'If that email has an account, a reset link is on its way.');
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = AppScope.of(context).config;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 48, 22, 24),
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(color: context.cs.primary, borderRadius: BorderRadius.circular(18)),
              child: Icon(Icons.waves, color: context.cs.onPrimary, size: 30),
            ),
            const SizedBox(height: 14),
            Text('Steady', style: context.tt.displaySmall?.copyWith(fontWeight: FontWeight.w600)),
            Text('Between-session check-ins for ${cfg.practiceName}', style: context.tt.bodyLarge?.copyWith(color: context.sc.ink2)),
            const SizedBox(height: 28),
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
                  Text('Your psychologist will give you an invite code.', style: TextStyle(color: context.sc.ink2)),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const JoinScreen())),
                    child: const Text('I have an invite code'),
                  ),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
