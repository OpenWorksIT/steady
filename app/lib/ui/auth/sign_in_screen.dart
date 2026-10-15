// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../services/api.dart';
import '../theme.dart';
import '../widgets.dart';
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
