// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../services/api.dart';
import '../theme.dart';
import '../widgets.dart';

class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key});
  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _consent = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_code, _name, _email, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _join() async {
    setState(() => _error = null);
    final state = AppScope.of(context);
    final nav = Navigator.of(context);
    try {
      await state.api.join(
        code: _code.text,
        name: _name.text.trim(),
        email: _email.text.trim(),
        password: _password.text,
        consent: _consent,
      );
      nav.popUntil((r) => r.isFirst);
      await state.signedInNow();
    } catch (e) {
      setState(() => _error = errorText(e));
    }
  }

  void _showConsent(String text) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        builder: (c, sc) => ListView(
          controller: sc,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
          children: [SelectableText(text.isEmpty ? 'The practice has not published its consent statement yet.' : text)],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cfg = AppScope.of(context).config;
    return Scaffold(
      appBar: AppBar(title: const Text('Join with an invite code')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
          children: [
            TextField(
              controller: _code,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'Invite code', hintText: 'ABCD-2345'),
            ),
            const SizedBox(height: 12),
            TextField(controller: _name, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Your name')),
            const SizedBox(height: 12),
            TextField(controller: _email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email')),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Choose a password', helperText: 'At least 10 characters'),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  CheckboxListTile(
                    value: _consent,
                    onChanged: (v) => setState(() => _consent = v ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    title: Text('I have read and agree to how ${cfg.practiceName} will use my information'),
                  ),
                  TextButton(onPressed: () => _showConsent(cfg.consentText), child: const Text('Read the consent statement')),
                ]),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: TextStyle(color: context.cs.error)),
            ],
            const SizedBox(height: 16),
            BusyButton(label: 'Create my account', onPressed: _consent ? _join : null),
            const SizedBox(height: 24),
            const CrisisFooter(),
          ],
        ),
      ),
    );
  }
}
