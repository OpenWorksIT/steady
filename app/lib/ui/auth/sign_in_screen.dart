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
  final _emailCode = TextEditingController();
  bool _needCode = false;
  // a staff member on a new device: the code we emailed links it
  DeviceLinkNeeded? _link;
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
    _emailCode.dispose();
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
    } on DeviceLinkNeeded catch (l) {
      setState(() => _link = l);
    } catch (e) {
      setState(() => _error = errorText(e).contains('Failed to authenticate') ? 'That email and password didn\'t match.' : errorText(e));
    }
  }

  Future<void> _linkDevice() async {
    setState(() => _error = null);
    final state = AppScope.of(context);
    try {
      await state.api.linkDevice(_link!.ticket, _emailCode.text);
      await state.signedInNow();
    } catch (e) {
      final msg = errorText(e);
      setState(() {
        _error = msg;
        // an expired code: start again from the password
        if (msg.contains('expired')) _startAgain();
      });
    }
  }

  void _startAgain() {
    _link = null;
    _needCode = false;
    _code.clear();
    _emailCode.clear();
  }

  // Lost or stolen phone (staff): locks the account from any device with email and password,
  // since the authenticator may be on the lost phone. Only OpenWorks IT unlocks it.
  Future<void> _lockAccount() async {
    final email = TextEditingController(text: _email.text);
    final password = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Lock your account'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('For practice staff whose phone is lost or stolen. Steady signs you out everywhere at once and unlinks '
                'all your devices. To use Steady again, contact OpenWorks IT support: they check it\'s really you and unlock it.'),
            const SizedBox(height: 12),
            TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email')),
            const SizedBox(height: 8),
            TextField(controller: password, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Lock my account')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    try {
      await AppScope.api(context).lockAccount(email.text, password.text);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Your account is locked'),
          content: const Text('You\'re signed out everywhere and no device is linked any more. We\'ve emailed you a note of it. '
              'Contact OpenWorks IT support to unlock your account.'),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
        ),
      );
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
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
            if (_link != null) ...[
              Text('Link this ${AppScope.api(context).isPhone ? 'phone' : 'browser'}', style: context.tt.titleMedium),
              const SizedBox(height: 6),
              Text('The first time you sign in on a device, we email you a code to make sure it\'s you. '
                  'We sent a 6-digit code to ${_link!.email}. It works for 15 minutes.',
                  style: TextStyle(color: context.sc.ink2)),
              const SizedBox(height: 12),
              TextField(
                controller: _emailCode,
                autofocus: true,
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                decoration: const InputDecoration(labelText: 'Code from the email'),
                onSubmitted: (_) => _linkDevice(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: TextStyle(color: context.cs.error)),
              ],
              const SizedBox(height: 16),
              BusyButton(label: 'Link and sign in', onPressed: _linkDevice),
              TextButton(
                onPressed: () => setState(_startAgain),
                child: const Text('No email? Check spam, or start again for a new code'),
              ),
            ] else ...[
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
            TextButton(onPressed: _lockAccount, child: const Text('Staff: lost your phone? Lock your account')),
            ],
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
