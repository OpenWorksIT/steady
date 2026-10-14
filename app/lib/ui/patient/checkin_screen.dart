// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../widgets.dart';
import 'done_screen.dart';

class CheckinScreen extends StatefulWidget {
  const CheckinScreen({super.key});
  @override
  State<CheckinScreen> createState() => _CheckinScreenState();
}

class _CheckinScreenState extends State<CheckinScreen> {
  static const _questions = [
    ('mood', 'How is your mood right now?', 'Very low', 'Very good'),
    ('anxiety', 'How anxious or tense do you feel?', 'Not at all', 'Extremely'),
    ('sleep', 'How did you sleep last night?', 'Very badly', 'Very well'),
    ('energy', 'How is your energy today?', 'Exhausted', 'Full of energy'),
  ];
  final Map<String, int> _scores = {};
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  bool get _ready => _questions.every((q) => _scores[q.$1] != null);

  Future<void> _send() async {
    final api = AppScope.api(context);
    final nav = Navigator.of(context);
    await api.addCheckin(
      mood: _scores['mood']!,
      anxiety: _scores['anxiety']!,
      sleep: _scores['sleep']!,
      energy: _scores['energy']!,
      note: _note.text.trim(),
    );
    nav.pushReplacement(MaterialPageRoute(builder: (_) => const DoneScreen(message: 'Your check-in has been sent to your psychologist.')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Check-in')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
          children: [
            for (final q in _questions) ...[
              ScalePicker(
                question: q.$2,
                low: q.$3,
                high: q.$4,
                value: _scores[q.$1],
                onChanged: (v) => setState(() => _scores[q.$1] = v),
              ),
              const SizedBox(height: 20),
            ],
            TextField(
              controller: _note,
              maxLines: 4,
              maxLength: 1000,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'In a few words, how are you feeling?', hintText: 'Optional', alignLabelWithHint: true),
            ),
            const SizedBox(height: 8),
            BusyButton(label: 'Send to my psychologist', onPressed: _ready ? _send : null),
            const SizedBox(height: 20),
            const CrisisFooter(),
          ],
        ),
      ),
    );
  }
}
