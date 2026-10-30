// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_state.dart';
import '../../services/api.dart';
import '../brand.dart';
import '../theme.dart';
import '../widgets.dart';

/// Sets up two-step sign-in: scan a QR code into an authenticator app, type the first code,
/// keep the recovery codes. [forced]: staff can't use the app until this is done.
class TwoStepSetupScreen extends StatefulWidget {
  final bool forced;
  const TwoStepSetupScreen({this.forced = false, super.key});
  @override
  State<TwoStepSetupScreen> createState() => _TwoStepSetupScreenState();
}

class _TwoStepSetupScreenState extends State<TwoStepSetupScreen> {
  ({String secret, String uri})? _start;
  List<String>? _recovery;
  final _code = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _begin());
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _begin() async {
    try {
      final s = await AppScope.api(context).twoStepStart();
      if (mounted) setState(() => _start = s);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  Future<void> _confirm() async {
    setState(() => _error = null);
    try {
      final codes = await AppScope.api(context).twoStepConfirm(_code.text);
      if (mounted) setState(() => _recovery = codes);
    } catch (e) {
      setState(() => _error = errorText(e));
    }
  }

  void _done() {
    final state = AppScope.of(context);
    if (!widget.forced) Navigator.of(context).pop();
    state.changed();
    state.signedInNow();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Scaffold(
      appBar: widget.forced ? null : AppBar(title: const Text('Two-step sign-in')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 28, 22, 24),
          children: _recovery != null ? _recoveryView(context) : _setupView(context, state),
        ),
      ),
    );
  }

  List<Widget> _setupView(BuildContext context, AppState state) => [
        if (widget.forced) ...[
          PracticeHeader(name: state.config.practiceName),
          const SizedBox(height: 22),
        ],
        Text('Set up two-step sign-in', style: context.tt.headlineSmall),
        const SizedBox(height: 6),
        Text(
          'Your account can open patient information, so signing in needs your password and a 6-digit code '
          'from an authenticator app on your phone. Aegis and 2FAS are free and open source; '
          'Google and Microsoft Authenticator work too.',
          style: TextStyle(color: context.sc.ink2),
        ),
        const SizedBox(height: 18),
        if (_start == null && _error == null) const Center(child: CircularProgressIndicator()),
        if (_start != null) ...[
          Text('1. In the authenticator app, add an account and scan this code', style: context.tt.titleSmall),
          const SizedBox(height: 10),
          Center(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
              child: QrImageView(data: _start!.uri, size: 210, backgroundColor: Colors.white, semanticsLabel: 'Two-step sign-in QR code'),
            ),
          ),
          const SizedBox(height: 8),
          Text('Setting up on this phone? Open the app directly, or type the key:', style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
          Row(children: [
            Expanded(child: SelectableText(_grouped(_start!.secret), style: const TextStyle(fontFamily: 'monospace', letterSpacing: 1))),
            IconButton(
              tooltip: 'Copy key',
              icon: const Icon(Icons.copy),
              onPressed: () {
                copySecret(_start!.secret);
                showSnack(context, 'Key copied. It\'s cleared from the clipboard in a minute.');
              },
            ),
            IconButton(
              tooltip: 'Open in authenticator app',
              icon: const Icon(Icons.open_in_new),
              onPressed: () => launchUrl(Uri.parse(_start!.uri), mode: LaunchMode.externalApplication).catchError((_) => false),
            ),
          ]),
          const SizedBox(height: 16),
          Text('2. Type the 6-digit code it shows', style: context.tt.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _code,
            keyboardType: TextInputType.number,
            autofillHints: const [AutofillHints.oneTimeCode],
            maxLength: 6,
            decoration: const InputDecoration(labelText: 'Code', counterText: ''),
            onSubmitted: (_) => _confirm(),
          ),
          const SizedBox(height: 12),
          BusyButton(label: 'Switch on', onPressed: _confirm),
        ],
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: TextStyle(color: context.cs.error)),
          if (_start == null) TextButton(onPressed: _begin, child: const Text('Try again')),
        ],
        if (widget.forced) ...[
          const SizedBox(height: 12),
          TextButton(onPressed: () => state.signOut(), child: const Text('Sign out')),
        ],
      ];

  List<Widget> _recoveryView(BuildContext context) => [
        Icon(Icons.verified_user_outlined, size: 48, color: context.cs.primary),
        const SizedBox(height: 10),
        Text('Two-step sign-in is on', style: context.tt.headlineSmall),
        const SizedBox(height: 6),
        Text(
          'Keep these recovery codes somewhere safe, away from this phone (printed, or in a password manager). '
          'Each one signs you in once if you lose your phone. They won\'t be shown again.',
          style: TextStyle(color: context.sc.ink2),
        ),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Wrap(spacing: 18, runSpacing: 8, children: [
              for (final c in _recovery!) SelectableText(c, style: const TextStyle(fontFamily: 'monospace', fontSize: 16)),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.copy),
          onPressed: () {
            copySecret(_recovery!.join('\n'));
            showSnack(context, 'Recovery codes copied. Paste them into your password manager now: they\'re cleared from the clipboard in a minute.');
          },
          label: const Text('Copy codes'),
        ),
        const SizedBox(height: 12),
        FilledButton(onPressed: _done, child: const Text("I've kept them safe")),
      ];
}

String _grouped(String s) => [for (var i = 0; i < s.length; i += 4) s.substring(i, i + 4 > s.length ? s.length : i + 4)].join(' ');

/// Copies a secret, and clears the clipboard a minute later if it still holds it (keyboards keep
/// clipboard history, and other apps can read the clipboard).
void copySecret(String text) {
  Clipboard.setData(ClipboardData(text: text));
  Timer(const Duration(minutes: 1), () async {
    try {
      final now = await Clipboard.getData(Clipboard.kTextPlain);
      if (now?.text == text) await Clipboard.setData(const ClipboardData(text: ''));
    } catch (_) {/* best effort */}
  });
}
