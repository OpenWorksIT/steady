// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../models.dart';
import '../theme.dart';
import '../widgets.dart';
import 'done_screen.dart';

/// The right screen for an instrument. Without an assignmentId an exercise is self-started.
Widget activityScreenFor(Instrument i, {String? assignmentId}) {
  if (i.isQuestionnaire) return QuestionnaireScreen(instrument: i, assignmentId: assignmentId!);
  final ex = i.exercise;
  if (ex?.type == 'breathing') return BreathingScreen(instrument: i, assignmentId: assignmentId);
  return StepsScreen(instrument: i, assignmentId: assignmentId);
}

Future<void> _finishExercise(BuildContext context, Instrument i, String? assignmentId, Map<String, Object?> result) async {
  final api = AppScope.api(context);
  final nav = Navigator.of(context);
  if (assignmentId != null) {
    await api.completeExercise(assignmentId, result);
  } else {
    await api.selfStart(i.id, result);
  }
  nav.pushReplacement(MaterialPageRoute(
    builder: (_) => const DoneScreen(message: 'Well done. Your psychologist can see you finished this.'),
  ));
}

/* ------------------------------------------------------------------ questionnaire */

class QuestionnaireScreen extends StatefulWidget {
  final Instrument instrument;
  final String assignmentId;
  const QuestionnaireScreen({required this.instrument, required this.assignmentId, super.key});
  @override
  State<QuestionnaireScreen> createState() => _QuestionnaireScreenState();
}

class _QuestionnaireScreenState extends State<QuestionnaireScreen> {
  late final List<Item> _items = widget.instrument.items;
  final Map<String, Object?> _answers = {};

  /// Items that apply given the answers so far (answers to hidden items are dropped).
  List<Item> get _visible {
    final shown = <Item>[];
    final effective = <String, Object?>{};
    for (final it in _items) {
      if (it.visible(effective)) {
        shown.add(it);
        if (_answers.containsKey(it.id)) effective[it.id] = _answers[it.id];
      }
    }
    return shown;
  }

  bool _answered(Item it) {
    final v = _answers[it.id];
    if (v == null) return false;
    if (v is String) return v.trim().isNotEmpty;
    return true;
  }

  Future<void> _send() async {
    final api = AppScope.api(context);
    final nav = Navigator.of(context);
    final visible = _visible;
    final payload = {for (final it in visible) if (_answered(it)) it.id: _answers[it.id]};
    await api.completeQuestionnaire(widget.assignmentId, payload);
    nav.pushReplacement(MaterialPageRoute(builder: (_) => const DoneScreen(message: 'Your answers have been sent to your psychologist.')));
  }

  @override
  Widget build(BuildContext context) {
    final inst = widget.instrument;
    final visible = _visible;
    final required = visible.where((i) => i.required).toList();
    final left = required.where((i) => !_answered(i)).length;
    final done = visible.where(_answered).length;
    return Scaffold(
      appBar: AppBar(title: Text(inst.name)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 28),
          children: [
            LinearProgressIndicator(value: visible.isEmpty ? 0 : done / visible.length, minHeight: 4, borderRadius: BorderRadius.circular(2)),
            const SizedBox(height: 14),
            if (inst.fullName.isNotEmpty) Text(inst.fullName, style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
            if (inst.instructions.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(inst.instructions, style: context.tt.bodyLarge?.copyWith(color: context.sc.ink2)),
            ],
            const SizedBox(height: 12),
            for (var n = 0; n < visible.length; n++) _itemWidget(visible[n], n + 1, visible.length),
            const SizedBox(height: 8),
            BusyButton(label: left == 0 ? 'Send answers' : '$left left to answer', onPressed: left == 0 ? _send : null),
            const SizedBox(height: 10),
            if (inst.licenceName.isNotEmpty)
              Text('${inst.fullName.isEmpty ? inst.name : inst.fullName} · ${inst.licenceName}',
                  style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
            const SizedBox(height: 16),
            const CrisisFooter(),
          ],
        ),
      ),
    );
  }

  Widget _itemWidget(Item it, int n, int total) {
    Widget input;
    if (it.type == 'choice') {
      input = Column(children: [
        for (final o in it.options)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _OptionButton(
              label: o.label,
              selected: _answers[it.id] == o.value,
              onTap: () => setState(() => _answers[it.id] = o.value),
            ),
          ),
      ]);
    } else if (it.type == 'number') {
      input = TextFormField(
        initialValue: _answers[it.id]?.toString(),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(helperText: 'A number from ${it.min} to ${it.max}'),
        onChanged: (v) {
          final parsed = num.tryParse(v.trim());
          setState(() => _answers[it.id] = (parsed != null && parsed >= it.min && parsed <= it.max) ? parsed : null);
        },
      );
    } else {
      input = TextFormField(
        initialValue: _answers[it.id] as String?,
        maxLines: 3,
        maxLength: it.maxLength,
        decoration: InputDecoration(hintText: it.required ? null : 'Optional'),
        onChanged: (v) => setState(() => _answers[it.id] = v),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (it.preamble.isNotEmpty) ...[
          Text(it.preamble, style: context.tt.bodyMedium?.copyWith(color: context.sc.ink2)),
          const SizedBox(height: 6),
        ],
        Text('$n of $total', style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
        const SizedBox(height: 2),
        Text(it.text, style: context.tt.bodyLarge),
        input,
      ]),
    );
  }
}

class _OptionButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _OptionButton({required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) => Semantics(
        selected: selected,
        button: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: selected ? context.sc.accentSoft : context.cs.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: selected ? context.cs.primary : context.sc.line, width: 1.5),
            ),
            child: Row(children: [
              Expanded(child: Text(label, style: TextStyle(fontWeight: selected ? FontWeight.w700 : FontWeight.w400))),
              if (selected) Icon(Icons.check, size: 18, color: context.cs.primary),
            ]),
          ),
        ),
      );
}

/* ------------------------------------------------------------------ breathing */

class BreathingScreen extends StatefulWidget {
  final Instrument instrument;
  final String? assignmentId;
  const BreathingScreen({required this.instrument, this.assignmentId, super.key});
  @override
  State<BreathingScreen> createState() => _BreathingScreenState();
}

class _BreathingScreenState extends State<BreathingScreen> {
  late final ExerciseDef _ex = widget.instrument.exercise!;
  final _started = DateTime.now();
  Timer? _timer;
  int _round = 0; // completed rounds
  int _phase = -1;
  int _left = 0;
  bool _expanded = false;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 1200), _nextPhase);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _nextPhase() {
    if (!mounted) return;
    var phase = _phase + 1;
    var round = _round;
    if (phase >= _ex.phases.length) {
      phase = 0;
      round++;
    }
    if (round >= _ex.rounds) {
      setState(() => _round = round);
      _finish();
      return;
    }
    final p = _ex.phases[phase];
    setState(() {
      _phase = phase;
      _round = round;
      _left = p.seconds;
      _expanded = p.expand;
    });
    _tick();
  }

  void _tick() {
    _timer = Timer(const Duration(seconds: 1), () {
      if (!mounted) return;
      if (_left > 1) {
        setState(() => _left--);
        _tick();
      } else {
        _nextPhase();
      }
    });
  }

  Future<void> _finish() async {
    if (_finishing) return;
    _finishing = true;
    _timer?.cancel();
    try {
      await _finishExercise(context, widget.instrument, widget.assignmentId, {
        'rounds': _round,
        'seconds': DateTime.now().difference(_started).inSeconds,
      });
    } catch (e) {
      _finishing = false;
      if (mounted) showSnack(context, 'Couldn\'t send that. Check your connection and try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.of(context).disableAnimations;
    final label = _phase < 0 ? 'Get comfortable' : _ex.phases[_phase].label;
    final seconds = _phase < 0 ? 1 : _ex.phases[_phase].seconds;
    final size = MediaQuery.sizeOf(context).width.clamp(200.0, 320.0).toDouble() * 0.8;
    return Scaffold(
      appBar: AppBar(title: Text(widget.instrument.name)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
          children: [
            Text(widget.instrument.summary, textAlign: TextAlign.center, style: context.tt.bodyMedium?.copyWith(color: context.sc.ink2)),
            const SizedBox(height: 20),
            Center(
              child: SizedBox(
                width: size,
                height: size,
                child: Stack(alignment: Alignment.center, children: [
                  SizedBox.expand(
                    child: Container(
                      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: context.sc.line, width: 1.5)),
                    ),
                  ),
                  AnimatedScale(
                    scale: reduce ? 0.8 : (_expanded ? 1.0 : 0.42),
                    duration: reduce ? Duration.zero : Duration(seconds: seconds),
                    curve: Curves.easeInOut,
                    child: SizedBox.expand(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(colors: [context.sc.moodScale[2], context.cs.primary], center: const Alignment(-0.2, -0.3)),
                        ),
                      ),
                    ),
                  ),
                  if (_phase >= 0)
                    Text('$_left', style: TextStyle(color: context.cs.onPrimary, fontSize: 20, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
            const SizedBox(height: 20),
            Semantics(
              liveRegion: true,
              child: Text(label, textAlign: TextAlign.center, style: context.tt.headlineSmall),
            ),
            const SizedBox(height: 4),
            Text(_phase < 0 ? 'Starting in a moment' : 'Round ${_round + 1} of ${_ex.rounds}',
                textAlign: TextAlign.center, style: context.tt.bodyMedium?.copyWith(color: context.sc.ink3)),
            const SizedBox(height: 24),
            OutlinedButton(onPressed: _finish, child: const Text('Finish early')),
          ],
        ),
      ),
    );
  }
}

/* ------------------------------------------------------------------ steps */

class StepsScreen extends StatefulWidget {
  final Instrument instrument;
  final String? assignmentId;
  const StepsScreen({required this.instrument, this.assignmentId, super.key});
  @override
  State<StepsScreen> createState() => _StepsScreenState();
}

class _StepsScreenState extends State<StepsScreen> {
  late final List<StepDef> _steps = widget.instrument.exercise?.steps ?? const [];
  late final List<TextEditingController> _controllers = [for (final _ in _steps) TextEditingController()];
  int _i = 0;

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_steps.isEmpty) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('This exercise has no steps.')));
    }
    final s = _steps[_i];
    final last = _i == _steps.length - 1;
    return Scaffold(
      appBar: AppBar(title: Text(widget.instrument.name)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 28),
          children: [
            LinearProgressIndicator(value: (_i + 1) / _steps.length, minHeight: 4, borderRadius: BorderRadius.circular(2)),
            const SizedBox(height: 8),
            Text('Step ${_i + 1} of ${_steps.length}', style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
            const SizedBox(height: 10),
            Text(s.title, style: context.tt.headlineSmall),
            const SizedBox(height: 6),
            Text(s.prompt, style: context.tt.bodyLarge?.copyWith(color: context.sc.ink2)),
            const SizedBox(height: 16),
            TextField(
              key: ValueKey(_i),
              controller: _controllers[_i],
              maxLines: 5,
              maxLength: 2000,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(hintText: 'Write here if it helps (optional)'),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: _i == 0 ? null : () => setState(() => _i--), child: const Text('Back'))),
              const SizedBox(width: 10),
              Expanded(
                child: last
                    ? BusyButton(
                        label: 'Finish',
                        onPressed: () => _finishExercise(context, widget.instrument, widget.assignmentId, {
                          'answers': [for (final c in _controllers) c.text.trim()],
                        }),
                      )
                    : FilledButton(onPressed: () => setState(() => _i++), child: const Text('Next')),
              ),
            ]),
            const SizedBox(height: 20),
            const CrisisFooter(),
          ],
        ),
      ),
    );
  }
}
