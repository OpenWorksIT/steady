// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Create or edit a questionnaire or exercise. The server validates the result
// (pb_hooks/lib/core.js validateInstrument) and returns readable errors.
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../models.dart';
import '../../services/api.dart';
import '../theme.dart';
import '../widgets.dart';

const _presets = <String, List<(String, num)>>{
  'How often (0–3)': [('Not at all', 0), ('Several days', 1), ('More than half the days', 2), ('Nearly every day', 3)],
  'Agreement (0–4)': [('Strongly disagree', 0), ('Disagree', 1), ('Neutral', 2), ('Agree', 3), ('Strongly agree', 4)],
  'How much (0–4)': [('Not at all', 0), ('A little bit', 1), ('Moderately', 2), ('Quite a bit', 3), ('Extremely', 4)],
  'Yes / No': [('No', 0), ('Yes', 1)],
};

class _Q {
  final String? id; // kept when editing so earlier answers still line up
  final TextEditingController text;
  String type; // choice | text | number
  bool required;
  final TextEditingController flagAt; // optional: flag when answer >= this
  _Q({this.id, String t = '', this.type = 'choice', this.required = true, String flag = ''})
      : text = TextEditingController(text: t),
        flagAt = TextEditingController(text: flag);
  void dispose() {
    text.dispose();
    flagAt.dispose();
  }
}

class _Band {
  final TextEditingController min, max, label;
  String severity;
  _Band({String a = '', String b = '', String l = '', this.severity = 'none'})
      : min = TextEditingController(text: a),
        max = TextEditingController(text: b),
        label = TextEditingController(text: l);
  void dispose() {
    min.dispose();
    max.dispose();
    label.dispose();
  }
}

class _Opt {
  final TextEditingController label, value;
  _Opt(String l, num v)
      : label = TextEditingController(text: l),
        value = TextEditingController(text: '$v');
  void dispose() {
    label.dispose();
    value.dispose();
  }
}

class _StepRow {
  final TextEditingController title, prompt;
  _StepRow([String t = '', String p = ''])
      : title = TextEditingController(text: t),
        prompt = TextEditingController(text: p);
  void dispose() {
    title.dispose();
    prompt.dispose();
  }
}

class _PhaseRow {
  final TextEditingController label, seconds;
  bool expand;
  _PhaseRow(String l, int s, this.expand)
      : label = TextEditingController(text: l),
        seconds = TextEditingController(text: '$s');
  void dispose() {
    label.dispose();
    seconds.dispose();
  }
}

class BuilderScreen extends StatefulWidget {
  final Instrument? edit;
  final Instrument? copyFrom;
  const BuilderScreen({this.edit, this.copyFrom, super.key});
  @override
  State<BuilderScreen> createState() => _BuilderScreenState();
}

class _BuilderScreenState extends State<BuilderScreen> {
  String _kind = 'questionnaire'; // questionnaire | steps | breathing
  final _name = TextEditingController();
  final _fullName = TextEditingController();
  final _summary = TextEditingController();
  final _instructions = TextEditingController();
  final _rounds = TextEditingController(text: '4');
  final List<_Opt> _opts = [];
  final List<_Q> _qs = [];
  final List<_Band> _bands = [];
  final List<_StepRow> _steps = [];
  final List<_PhaseRow> _phases = [];
  bool _score = true;
  String? _error;
  String? _simplified;

  @override
  void initState() {
    super.initState();
    final src = widget.edit ?? widget.copyFrom;
    if (src == null) {
      _setPreset(_presets.keys.first);
      _qs.add(_Q());
      _steps.add(_StepRow());
      _phases.addAll([_PhaseRow('Breathe in', 4, true), _PhaseRow('Breathe out', 6, false)]);
      return;
    }
    _name.text = widget.copyFrom != null ? '${src.name} (copy)' : src.name;
    _fullName.text = src.fullName;
    _summary.text = src.summary;
    _instructions.text = src.instructions;
    final ex = src.exercise;
    if (src.isQuestionnaire) {
      final items = src.items;
      final firstChoice = items.where((i) => i.type == 'choice').firstOrNull;
      for (final o in (firstChoice?.options ?? _presets.values.first.map((p) => ChoiceOption(p.$1, p.$2)).toList())) {
        _opts.add(_Opt(o.label, o.value));
      }
      final scoring = asMap(src.definition['scoring']);
      final flags = {for (final f in asList(scoring['itemFlags']).map(asMap)) '${f['item']}': f};
      for (final it in items) {
        final f = flags[it.id];
        _qs.add(_Q(id: it.id, t: it.text, type: it.type, required: it.required, flag: f != null && f['op'] == '>=' ? '${f['value']}' : (f != null && f['op'] == '>' ? '${(f['value'] as num) + 1}' : '')));
      }
      _score = scoring.isNotEmpty;
      final lost = <String>[
        if (items.any((i) => i.showIf.isNotEmpty)) 'conditional questions',
        if (asList(scoring['subscales']).isNotEmpty) 'sub-scores',
        if (items.where((i) => i.type == 'choice').map((i) => i.options.map((o) => '${o.label}=${o.value}').join('|')).toSet().length > 1)
          'different answer options per question',
        if (scoring['multiplier'] is num && scoring['multiplier'] != 1) 'score multiplier',
      ];
      if (lost.isNotEmpty) _simplified = 'This editor keeps things simple, so ${lost.join(', ')} from the original are not carried over. Check the copy before sending it.';
      for (final b in asList(scoring['bands']).map(asMap)) {
        _bands.add(_Band(a: '${b['min']}', b: '${b['max']}', l: '${b['label'] ?? ''}', severity: '${b['severity'] ?? 'none'}'));
      }
      _steps.add(_StepRow());
      _phases.addAll([_PhaseRow('Breathe in', 4, true), _PhaseRow('Breathe out', 6, false)]);
    } else {
      _kind = ex?.type == 'breathing' ? 'breathing' : 'steps';
      _rounds.text = '${ex?.rounds ?? 4}';
      for (final s in ex?.steps ?? const <StepDef>[]) {
        _steps.add(_StepRow(s.title, s.prompt));
      }
      for (final p in ex?.phases ?? const <Phase>[]) {
        _phases.add(_PhaseRow(p.label, p.seconds, p.expand));
      }
      if (_steps.isEmpty) _steps.add(_StepRow());
      if (_phases.isEmpty) _phases.addAll([_PhaseRow('Breathe in', 4, true), _PhaseRow('Breathe out', 6, false)]);
      _setPreset(_presets.keys.first);
      _qs.add(_Q());
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _fullName, _summary, _instructions, _rounds]) {
      c.dispose();
    }
    for (final x in [..._opts, ..._qs, ..._bands, ..._steps, ..._phases]) {
      (x as dynamic).dispose();
    }
    super.dispose();
  }

  void _setPreset(String name) {
    for (final o in _opts) {
      o.dispose();
    }
    _opts
      ..clear()
      ..addAll(_presets[name]!.map((p) => _Opt(p.$1, p.$2)));
  }

  String _slug(String s) {
    final base = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    final stamp = DateTime.now().millisecondsSinceEpoch.toRadixString(36).substring(4);
    return '${base.isEmpty ? 'custom' : (base.length > 40 ? base.substring(0, 40) : base)}-$stamp';
  }

  Map<String, dynamic> _definition() {
    final def = <String, dynamic>{
      'key': widget.edit?.key ?? _slug(_name.text),
      'name': _name.text.trim(),
      'fullName': _fullName.text.trim(),
      'summary': _summary.text.trim(),
      'version': '1',
      'language': 'en',
    };
    if (_kind == 'questionnaire') {
      def['kind'] = 'questionnaire';
      def['instructions'] = _instructions.text.trim();
      def['responseSets'] = {
        'scale': [
          for (final o in _opts)
            if (o.label.text.trim().isNotEmpty) {'label': o.label.text.trim(), 'value': num.tryParse(o.value.text.trim()) ?? 0},
        ],
      };
      final items = <Map<String, dynamic>>[];
      final flags = <Map<String, dynamic>>[];
      final used = <String>{for (final q in _qs) if (q.id != null) q.id!};
      var next = 1;
      for (var i = 0; i < _qs.length; i++) {
        final q = _qs[i];
        if (q.text.text.trim().isEmpty) continue;
        var id = q.id;
        if (id == null) {
          while (used.contains('q$next')) {
            next++;
          }
          id = 'q$next';
          used.add(id);
        }
        items.add({
          'id': id,
          'text': q.text.text.trim(),
          'type': q.type,
          'required': q.required,
          if (q.type == 'choice') 'responseSet': 'scale',
        });
        final at = num.tryParse(q.flagAt.text.trim());
        if (q.type == 'choice' && at != null) {
          flags.add({'item': id, 'op': '>=', 'value': at, 'label': 'Question ${i + 1} at or above $at: review', 'severity': 'alert'});
        }
      }
      def['items'] = items;
      if (_score && items.any((i) => i['type'] == 'choice')) {
        def['scoring'] = {
          'method': 'sum',
          'bands': [
            for (final b in _bands)
              if (num.tryParse(b.min.text) != null && num.tryParse(b.max.text) != null)
                {'min': num.parse(b.min.text), 'max': num.parse(b.max.text), 'label': b.label.text.trim(), 'severity': b.severity},
          ],
          'itemFlags': flags,
        };
      }
    } else {
      def['kind'] = 'exercise';
      def['items'] = <Object>[];
      def['exercise'] = _kind == 'steps'
          ? {
              'type': 'steps',
              'steps': [
                for (final s in _steps)
                  if (s.title.text.trim().isNotEmpty) {'title': s.title.text.trim(), 'prompt': s.prompt.text.trim()},
              ],
            }
          : {
              'type': 'breathing',
              'rounds': int.tryParse(_rounds.text.trim()) ?? 4,
              'phases': [
                for (final p in _phases)
                  {'label': p.label.text.trim(), 'seconds': int.tryParse(p.seconds.text.trim()) ?? 4, 'expand': p.expand},
              ],
            };
    }
    return def;
  }

  Future<void> _save() async {
    setState(() => _error = null);
    final api = AppScope.api(context);
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (widget.edit != null) {
        await api.updateInstrument(widget.edit!.id, _definition());
      } else {
        await api.createInstrument(_definition());
      }
      messenger.showSnackBar(SnackBar(content: Text('${_name.text.trim()} saved to your library')));
      nav.pop(true);
    } catch (e) {
      setState(() => _error = errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.edit != null ? 'Edit ${widget.edit!.name}' : 'New')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            if (widget.edit == null)
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'questionnaire', label: Text('Questionnaire')),
                  ButtonSegment(value: 'steps', label: Text('Steps')),
                  ButtonSegment(value: 'breathing', label: Text('Breathing')),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => setState(() => _kind = s.first),
              ),
            if (_simplified != null) ...[
              const SizedBox(height: 8),
              Text(_simplified!, style: TextStyle(color: context.sc.warn)),
            ],
            const SizedBox(height: 14),
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'Short name', hintText: 'e.g. Sleep check')),
            const SizedBox(height: 10),
            TextField(controller: _fullName, decoration: const InputDecoration(labelText: 'Full name (optional)')),
            const SizedBox(height: 10),
            TextField(controller: _summary, decoration: const InputDecoration(labelText: 'One line patients see (optional)', hintText: 'e.g. 5 questions, about 2 minutes')),
            const SizedBox(height: 10),
            if (_kind == 'questionnaire') ..._questionnaireEditor(context),
            if (_kind == 'steps') ..._stepsEditor(context),
            if (_kind == 'breathing') ..._breathingEditor(context),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: context.cs.error)),
            ],
            const SizedBox(height: 16),
            BusyButton(label: 'Save to library', onPressed: _save),
          ],
        ),
      ),
    );
  }

  List<Widget> _questionnaireEditor(BuildContext context) => [
        TextField(
          controller: _instructions,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'Instructions', hintText: 'e.g. Over the last 2 weeks, how often...'),
        ),
        const SectionHeader('Answer options'),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final p in _presets.keys) ActionChip(label: Text(p), onPressed: () => setState(() => _setPreset(p))),
        ]),
        const SizedBox(height: 8),
        for (final (i, o) in _opts.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              Expanded(flex: 4, child: TextField(controller: o.label, decoration: const InputDecoration(labelText: 'Label', isDense: true))),
              const SizedBox(width: 8),
              SizedBox(
                width: 70,
                child: TextField(controller: o.value, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Score', isDense: true)),
              ),
              IconButton(
                tooltip: 'Remove option',
                onPressed: _opts.length <= 2 ? null : () => setState(() => _opts.removeAt(i).dispose()),
                icon: const Icon(Icons.close),
              ),
            ]),
          ),
        TextButton.icon(onPressed: () => setState(() => _opts.add(_Opt('', _opts.length))), icon: const Icon(Icons.add), label: const Text('Add option')),
        const SectionHeader('Questions'),
        for (final (i, q) in _qs.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text('Question ${i + 1}', style: context.tt.labelLarge),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Move up',
                      onPressed: i == 0 ? null : () => setState(() => _qs.insert(i - 1, _qs.removeAt(i))),
                      icon: const Icon(Icons.arrow_upward, size: 20),
                    ),
                    IconButton(
                      tooltip: 'Remove question',
                      onPressed: _qs.length <= 1 ? null : () => setState(() => _qs.removeAt(i).dispose()),
                      icon: const Icon(Icons.delete_outline, size: 20),
                    ),
                  ]),
                  TextField(controller: q.text, maxLines: 2, decoration: const InputDecoration(labelText: 'Question text')),
                  const SizedBox(height: 8),
                  Row(children: [
                    DropdownButton<String>(
                      value: q.type,
                      onChanged: (v) => setState(() => q.type = v ?? 'choice'),
                      items: const [
                        DropdownMenuItem(value: 'choice', child: Text('Options above')),
                        DropdownMenuItem(value: 'text', child: Text('Written answer')),
                        DropdownMenuItem(value: 'number', child: Text('Number')),
                      ],
                    ),
                    const Spacer(),
                    const Text('Required'),
                    Switch(value: q.required, onChanged: (v) => setState(() => q.required = v)),
                  ]),
                  if (q.type == 'choice')
                    TextField(
                      controller: q.flagAt,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Flag for review when the score is at least (optional)',
                        isDense: true,
                      ),
                    ),
                ]),
              ),
            ),
          ),
        TextButton.icon(onPressed: () => setState(() => _qs.add(_Q())), icon: const Icon(Icons.add), label: const Text('Add question')),
        const SectionHeader('Scoring'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Add up the option scores'),
          value: _score,
          onChanged: (v) => setState(() => _score = v),
        ),
        if (_score) ...[
          Text('Score bands (optional). Each band names a range of totals.', style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
          const SizedBox(height: 6),
          for (final (i, b) in _bands.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                SizedBox(width: 56, child: TextField(controller: b.min, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'From', isDense: true))),
                const SizedBox(width: 6),
                SizedBox(width: 56, child: TextField(controller: b.max, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'To', isDense: true))),
                const SizedBox(width: 6),
                Expanded(child: TextField(controller: b.label, decoration: const InputDecoration(labelText: 'Label', isDense: true))),
                PopupMenuButton<String>(
                  tooltip: 'How to show it',
                  initialValue: b.severity,
                  onSelected: (v) => setState(() => b.severity = v),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'none', child: Text('Plain')),
                    PopupMenuItem(value: 'info', child: Text('Note')),
                    PopupMenuItem(value: 'warn', child: Text('Amber')),
                    PopupMenuItem(value: 'alert', child: Text('Red')),
                  ],
                  child: Padding(padding: const EdgeInsets.all(6), child: FlagChip(b.severity, severityOf(b.severity))),
                ),
                IconButton(onPressed: () => setState(() => _bands.removeAt(i).dispose()), icon: const Icon(Icons.close)),
              ]),
            ),
          TextButton.icon(onPressed: () => setState(() => _bands.add(_Band())), icon: const Icon(Icons.add), label: const Text('Add band')),
        ],
      ];

  List<Widget> _stepsEditor(BuildContext context) => [
        const SectionHeader('Steps'),
        for (final (i, s) in _steps.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(children: [
                  Row(children: [
                    Text('Step ${i + 1}', style: context.tt.labelLarge),
                    const Spacer(),
                    IconButton(
                      onPressed: _steps.length <= 1 ? null : () => setState(() => _steps.removeAt(i).dispose()),
                      icon: const Icon(Icons.delete_outline, size: 20),
                    ),
                  ]),
                  TextField(controller: s.title, decoration: const InputDecoration(labelText: 'Heading')),
                  const SizedBox(height: 8),
                  TextField(controller: s.prompt, maxLines: 2, decoration: const InputDecoration(labelText: 'Prompt')),
                ]),
              ),
            ),
          ),
        TextButton.icon(onPressed: () => setState(() => _steps.add(_StepRow())), icon: const Icon(Icons.add), label: const Text('Add step')),
      ];

  List<Widget> _breathingEditor(BuildContext context) => [
        const SectionHeader('Pattern'),
        for (final (i, p) in _phases.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              Expanded(child: TextField(controller: p.label, decoration: const InputDecoration(labelText: 'Label', isDense: true))),
              const SizedBox(width: 6),
              SizedBox(width: 70, child: TextField(controller: p.seconds, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Seconds', isDense: true))),
              IconButton(
                tooltip: p.expand ? 'Circle grows' : 'Circle shrinks',
                onPressed: () => setState(() => p.expand = !p.expand),
                icon: Icon(p.expand ? Icons.open_in_full : Icons.close_fullscreen),
              ),
              IconButton(
                onPressed: _phases.length <= 1 ? null : () => setState(() => _phases.removeAt(i).dispose()),
                icon: const Icon(Icons.close),
              ),
            ]),
          ),
        TextButton.icon(onPressed: () => setState(() => _phases.add(_PhaseRow('Hold', 4, true))), icon: const Icon(Icons.add), label: const Text('Add phase')),
        TextField(controller: _rounds, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Rounds')),
      ];
}
