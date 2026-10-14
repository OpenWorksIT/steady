// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../services/api.dart';
import '../theme.dart';
import '../widgets.dart';

/// Asks for the practice's server address. Shown on first launch of test builds,
/// and from the sign-in screen when the address isn't fixed at build time.
class ServerScreen extends StatefulWidget {
  final bool firstRun;
  const ServerScreen({this.firstRun = true, super.key});
  @override
  State<ServerScreen> createState() => _ServerScreenState();
}

class _ServerScreenState extends State<ServerScreen> {
  late final _url = TextEditingController(text: AppScope.api(context).serverUrl);
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _error = null);
    final state = AppScope.of(context);
    final nav = Navigator.of(context);
    try {
      await state.setServer(_url.text);
      if (!widget.firstRun && nav.canPop()) nav.pop();
    } catch (e) {
      setState(() => _error = errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.firstRun ? null : AppBar(title: const Text('Server')),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(22, widget.firstRun ? 48 : 8, 22, 24),
          children: [
            if (widget.firstRun) ...[
              Text('Steady', style: context.tt.displaySmall?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
            ],
            Text('Enter the server address your practice gave you.', style: context.tt.bodyLarge?.copyWith(color: context.sc.ink2)),
            const SizedBox(height: 18),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Server address', hintText: 'steady.example.co.za'),
              onSubmitted: (_) => _save(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: TextStyle(color: context.cs.error)),
            ],
            const SizedBox(height: 16),
            BusyButton(label: 'Connect', onPressed: _save),
            if (!widget.firstRun) ...[
              const SizedBox(height: 12),
              Text('Changing the server signs you out.', style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
            ],
          ],
        ),
      ),
    );
  }
}
