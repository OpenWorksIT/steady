// SPDX-License-Identifier: AGPL-3.0-or-later
//
// RADR one tap down (deeper, not broader): why a day, an area or a flag is rated as it is, in
// plain words from the server (server/pb_hooks/lib/radr.js explain), with the days and values
// behind each number; marking a flag as reviewed (who and when); and why a patient is where they
// are in the list. RADR orders the list to improve care; it is never an alert. Opening an
// explanation is written to the access log on the server.
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../models.dart';
import '../../services/api.dart';
import '../theme.dart';
import '../widgets.dart';
import 'patient_care.dart' show radrDomainNames;

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// "2026-11-02" -> "Mon 2 Nov".
String radrDay(String day) {
  final d = DateTime.tryParse(day);
  if (d == null) return day;
  return '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';
}

String _shortDay(String day) {
  final d = DateTime.tryParse(day);
  return d == null ? day : '${d.day} ${_months[d.month - 1]}';
}

/// "Reviewed by Dr Demo, 2 Nov 2026".
String reviewedText(FlagReview r) {
  final at = r.at;
  return 'Reviewed by ${r.by}${at == null ? '' : ', ${at.day} ${_months[at.month - 1]} ${at.year}'}';
}

String _two(int n) => n.toString().padLeft(2, '0');

String _hm(num minutes) {
  final m = minutes.round().abs();
  return m < 60 ? '$m min' : '${m ~/ 60} h ${_two(m % 60)}';
}

String _clock(num minutes) {
  final m = minutes.round() % 1440;
  return '${_two(m ~/ 60)}:${_two(m % 60)}';
}

/// A measure's value as people read it (the server's words use the same).
String radrValue(String key, Object? v) {
  if (v is! num) return '-';
  return switch (key) {
    'sleep_min' => _hm(v),
    'sleep_var' => '${v.round()} min',
    'midpoint' => _clock(v),
    'steps' => '${v.round()} steps',
    'rhr' => '${v.toStringAsFixed(1)} bpm',
    'hrv' => '${v.round()} ms',
    _ => '${v.toStringAsFixed(1)} of 5',
  };
}

String _areaName(String domain) => radrDomainNames[domain] ?? domain;

/* ---------------- marking a flag as reviewed ---------------- */

/// Asks for an optional note and marks one RADR flag as reviewed. Returns true when done.
Future<bool> reviewRadrFlow(BuildContext context, String patientId, {required String key, required String domain, required String since}) async {
  final api = AppScope.api(context);
  final note = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Mark as reviewed'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('RADR: ${_areaName(domain)} away from usual since ${radrDay(since)}', style: c.tt.titleSmall),
        const SizedBox(height: 8),
        Text('It stays here with your name and the date, and no longer moves them up your list until something new shows in their '
            'watch data.',
            style: TextStyle(color: c.sc.ink2)),
        const SizedBox(height: 12),
        TextField(
          // keyboards don't learn from what's typed here
          enableIMEPersonalizedLearning: false,
          controller: note,
          minLines: 2,
          maxLines: 4,
          maxLength: 500,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'What you did (optional)', helperText: 'Kept with the review', border: OutlineInputBorder()),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Mark as reviewed')),
      ],
    ),
  );
  final text = note.text.trim();
  note.dispose();
  if (ok != true) return false;
  try {
    await api.reviewRadr(patientId, key, text);
    if (context.mounted) showSnack(context, 'Marked as reviewed');
    return true;
  } catch (e) {
    if (context.mounted) showSnack(context, errorText(e));
    return false;
  }
}

/* ---------------- one day explained ---------------- */

/// Opens the explanation of [day] (default: the latest rated day) for one patient. [focus]: the
/// area to open on ('sleep', 'circadian', 'activity', 'cardiac' or 'checkins'), or null for the
/// whole day. [onChanged] runs after a flag is marked as reviewed.
Future<void> showRadrExplain(BuildContext context, String patientId, {String? day, String? focus, VoidCallback? onChanged}) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => _ExplainSheet(patientId: patientId, day: day, focus: focus, onChanged: onChanged),
    );

class _ExplainSheet extends StatefulWidget {
  final String patientId;
  final String? day, focus;
  final VoidCallback? onChanged;
  const _ExplainSheet({required this.patientId, this.day, this.focus, this.onChanged});
  @override
  State<_ExplainSheet> createState() => _ExplainSheetState();
}

class _ExplainSheetState extends State<_ExplainSheet> {
  Key _key = UniqueKey();

  Future<void> _review(Map<String, dynamic> flag) async {
    final done = await reviewRadrFlow(context, widget.patientId,
        key: '${flag['key'] ?? ''}', domain: '${flag['domain'] ?? ''}', since: '${flag['since'] ?? ''}');
    if (!done || !mounted) return;
    widget.onChanged?.call();
    setState(() => _key = UniqueKey());
  }

  @override
  Widget build(BuildContext context) {
    final api = AppScope.api(context);
    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        maxChildSize: 0.95,
        builder: (c, scroll) => Loader<Map<String, dynamic>>(
          key: _key,
          load: () => api.radrExplain(widget.patientId, day: widget.day),
          builder: (c, x, _) => RadrExplainBody(x: x, focus: widget.focus, scroll: scroll, onReview: _review),
        ),
      ),
    );
  }
}

/// The explanation itself, from the server's answer [x] (GET .../radr/explain). [focus]: the
/// area to open on, or null for the whole day. [onReview]: marks a flag as reviewed (null: no
/// button).
class RadrExplainBody extends StatelessWidget {
  final Map<String, dynamic> x;
  final String? focus;
  final ScrollController? scroll;
  final void Function(Map<String, dynamic> flag)? onReview;
  const RadrExplainBody({required this.x, this.focus, this.scroll, this.onReview, super.key});

  @override
  Widget build(BuildContext c) {
    final measures = asMap(x['measures']);
    final domains = asMap(x['domains']);
    final flags = asList(x['flags']).map(asMap).toList();
    final focus = this.focus;
    final review = onReview;
    Map<String, dynamic>? flagFor(String domain) {
      for (final f in flags) {
        if (f['domain'] == domain) return f;
      }
      return null;
    }

    List<Map<String, dynamic>> measuresOf(Map<String, dynamic> area) => [for (final m in asList(area['measures'])) asMap(measures['$m'])];
    final areas = radrDomainNames.keys.toList();
    if (focus != null && areas.remove(focus)) areas.insert(0, focus);
    final checkins = asMap(x['checkins']);
    final checkinSection = _AreaSection(
      title: 'Check-ins',
      score: checkins['score'],
      status: 'What they reported, shown beside the watch',
      words: '${checkins['words'] ?? ''}',
      measures: measuresOf(checkins),
      expanded: focus == 'checkins',
    );
    final whole = [
      Text('${x['words'] ?? ''}'),
      const SizedBox(height: 12),
      if (flags.isNotEmpty) ...[
        const SectionHeader('Away from usual'),
        for (final f in flags) _FlagLine(flag: f, onReview: review == null ? null : () => review(f)),
        const SizedBox(height: 8),
      ],
    ];
    return ListView(controller: scroll, padding: const EdgeInsets.fromLTRB(20, 0, 20, 28), children: [
      Text(radrDay('${x['day'] ?? ''}'), style: c.tt.titleLarge),
      Text('RADR ${x['version'] ?? ''}: how far from their own normal, to improve care. Not a risk score, prediction or diagnosis.',
          style: c.tt.bodySmall?.copyWith(color: c.sc.ink3)),
      if (x['demo'] == true) ...[
        const SizedBox(height: 6),
        const Align(alignment: Alignment.centerLeft, child: FlagChip('Fictional demo patient: made-up data', Severity.none)),
      ],
      const SizedBox(height: 12),
      if (focus == null || focus == 'checkins') ...whole,
      if (focus == 'checkins') checkinSection,
      for (final k in areas)
        Builder(builder: (c) {
          final area = asMap(domains[k]);
          final flag = flagFor(k);
          final reviewed = flag == null ? const <String, dynamic>{} : asMap(flag['reviewed']);
          final score = area['score'];
          final status = area['counted'] == false
              ? 'Not counted for this patient'
              : flag != null
                  ? (reviewed.isNotEmpty
                      ? reviewedText(FlagReview.fromJson(reviewed))
                      : 'Away from usual since ${radrDay('${flag['since'] ?? ''}')}')
                  : score is num
                      ? (area['away'] == true ? 'Away from usual' : 'Near usual')
                      : 'No data';
          return _AreaSection(
            title: '${area['label'] ?? _areaName(k)}',
            score: score,
            status: status,
            words: '${area['words'] ?? ''}',
            measures: measuresOf(area),
            expanded: focus == k,
            flag: flag,
            onReview: flag == null || review == null ? null : () => review(flag),
          );
        }),
      if (focus != 'checkins') checkinSection,
      if (focus != null && focus != 'checkins') ...[
        const SizedBox(height: 8),
        const SectionHeader('The whole day'),
        ...whole,
      ],
      const SizedBox(height: 8),
      Text('Each value is an average of the last 3 days or nights (irregularity: 7 nights). Their usual is the middle of the 4 weeks '
          'ending a week earlier, and "give or take" is how much it usually varies. RADR counts how many of those it is away, in one '
          'direction only for most measures, up to 4. Sources and limits: docs/RADR.md in the Steady repository.',
          style: c.tt.bodySmall?.copyWith(color: c.sc.ink3)),
    ]);
  }
}

/// One flag in the whole-day view: what it is, and its review.
class _FlagLine extends StatelessWidget {
  final Map<String, dynamic> flag;
  final VoidCallback? onReview;
  const _FlagLine({required this.flag, required this.onReview});
  @override
  Widget build(BuildContext context) {
    final r = asMap(flag['reviewed']);
    final score = flag['score'];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${_areaName('${flag['domain']}')}: since ${radrDay('${flag['since'] ?? ''}')}'
            '${score is num ? ', ${score.toStringAsFixed(1)} of 4' : ''}', style: context.tt.titleSmall),
        _ReviewLine(review: r, onReview: onReview),
      ]),
    );
  }
}

/// "Reviewed by ..., date" with the note, or the button to mark it.
class _ReviewLine extends StatelessWidget {
  final Map<String, dynamic> review;
  final VoidCallback? onReview;
  const _ReviewLine({required this.review, required this.onReview});
  @override
  Widget build(BuildContext context) {
    if (review.isNotEmpty) {
      final r = FlagReview.fromJson(review);
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.check_circle, size: 16, color: context.sc.calm),
          const SizedBox(width: 6),
          Expanded(
            child: Text('${reviewedText(r)}${r.note.isEmpty ? '' : ': ${r.note}'}', style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
          ),
        ]),
      );
    }
    if (onReview == null) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(onPressed: onReview, icon: const Icon(Icons.check), label: const Text('Mark as reviewed')),
    );
  }
}

/// An area (or the check-ins): its score and status, then one tap down the words, each measure,
/// and the data behind them.
class _AreaSection extends StatelessWidget {
  final String title, status, words;
  final Object? score;
  final List<Map<String, dynamic>> measures;
  final bool expanded;
  final Map<String, dynamic>? flag;
  final VoidCallback? onReview;
  const _AreaSection({
    required this.title,
    required this.score,
    required this.status,
    required this.words,
    required this.measures,
    required this.expanded,
    this.flag,
    this.onReview,
  });
  @override
  Widget build(BuildContext context) {
    final s = score;
    final f = flag;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        initiallyExpanded: expanded,
        shape: const Border(),
        title: Row(children: [
          Expanded(child: Text(title, style: context.tt.titleMedium)),
          Text(s is num ? '${s.toStringAsFixed(1)} of 4' : '-', style: context.tt.titleSmall),
        ]),
        subtitle: Text(status, style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(words),
          if (f != null) _ReviewLine(review: asMap(f['reviewed']), onReview: onReview),
          for (final m in measures) _MeasureBlock(m),
        ],
      ),
    );
  }
}

/// One measure: the plain words, why it counts, and the days and values behind it.
class _MeasureBlock extends StatelessWidget {
  final Map<String, dynamic> m;
  const _MeasureBlock(this.m);
  @override
  Widget build(BuildContext context) {
    final key = '${m['key'] ?? ''}';
    final base = asMap(m['baseline']);
    final window = asList(m['window']).map(asMap).toList();
    final values = asList(base['values']).map(asMap).toList();
    final small = context.tt.bodySmall?.copyWith(color: context.sc.ink2);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${m['label'] ?? key}', style: context.tt.titleSmall),
        const SizedBox(height: 2),
        Text('${m['words'] ?? ''}'),
        const SizedBox(height: 4),
        Text('Why it counts: ${m['why'] ?? ''} ${m['rule'] ?? ''}', style: small),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          shape: const Border(),
          title: Text('The data behind it', style: context.tt.labelLarge),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          children: [
            Text(key == 'sleep_var' ? 'The 7 nights used for the value now:' : 'The readings averaged for the value now:', style: small),
            const SizedBox(height: 4),
            for (final w in window)
              Text(
                key == 'sleep_var'
                    ? '${radrDay('${w['day']}')}: fell asleep ${w['onset'] is num ? _clock(w['onset'] as num) : '-'}, '
                        'woke ${w['wake'] is num ? _clock(w['wake'] as num) : '-'}'
                    : '${radrDay('${w['day']}')}: ${w['value'] is num ? radrValue(key, w['value']) : 'no reading'}',
                style: context.tt.bodySmall,
              ),
            const SizedBox(height: 8),
            Text(
              values.isEmpty
                  ? 'No earlier values to compare with between ${radrDay('${base['from'] ?? ''}')} and ${radrDay('${base['to'] ?? ''}')}.'
                  : 'Their usual is the middle of these ${values.length} values (each a 3-day average), '
                      '${radrDay('${base['from'] ?? ''}')} to ${radrDay('${base['to'] ?? ''}')}:',
              style: small,
            ),
            const SizedBox(height: 4),
            Wrap(spacing: 14, runSpacing: 2, children: [
              for (final v in values) Text('${_shortDay('${v['day']}')}: ${radrValue(key, v['value'])}', style: context.tt.bodySmall),
            ]),
          ],
        ),
      ]),
    );
  }
}

/* ---------------- flags in lists ---------------- */

/// A RADR flag as a row: tap for the reasoning and the data, and to mark it as reviewed.
class RadrFlagTile extends StatelessWidget {
  final String patientId;
  final RadrFlag flag;
  final VoidCallback? onChanged;
  const RadrFlagTile({required this.patientId, required this.flag, this.onChanged, super.key});
  @override
  Widget build(BuildContext context) {
    final r = flag.reviewed;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(r != null ? Icons.check_circle_outline : Icons.insights_outlined, color: r != null ? context.sc.calm : context.cs.primary),
      title: Text('${_areaName(flag.domain)} away from usual'),
      subtitle: Text(r != null
          ? reviewedText(r)
          : 'Since ${radrDay(flag.since)}${flag.score == null ? '' : ' · ${flag.score!.toStringAsFixed(1)} of 4'} · not yet reviewed'),
      trailing: Icon(Icons.chevron_right, color: context.sc.ink3),
      onTap: () => showRadrExplain(context, patientId, day: flag.day, focus: flag.domain, onChanged: onChanged),
    );
  }
}

/// A RADR flag as a chip beside the other flags: never styled as an alert.
class RadrFlagChip extends StatelessWidget {
  final String patientId;
  final RadrFlag flag;
  final VoidCallback? onChanged;
  const RadrFlagChip({required this.patientId, required this.flag, this.onChanged, super.key});
  @override
  Widget build(BuildContext context) {
    final r = flag.reviewed;
    final label = 'RADR: ${_areaName(flag.domain)} away from usual';
    return Tooltip(
      message: r != null ? reviewedText(r) : 'Since ${radrDay(flag.since)}. Tap to see why.',
      child: InkWell(
        borderRadius: BorderRadius.circular(99),
        onTap: () => showRadrExplain(context, patientId, day: flag.day, focus: flag.domain, onChanged: onChanged),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (r != null) ...[Icon(Icons.check_circle, size: 16, color: context.sc.calm), const SizedBox(width: 3)],
          FlagChip(label, r != null ? Severity.none : Severity.info),
          Icon(Icons.more_horiz, size: 16, color: context.sc.ink3),
        ]),
      ),
    );
  }
}

/* ---------------- the order of the list ---------------- */

/// How the psychologist's list is ordered (core.js attention on the server).
class ListOrderNote extends StatelessWidget {
  const ListOrderNote({super.key});
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SectionHeader('How your list is ordered'),
        Text(
          '1. Answers not yet marked as reviewed, most serious first: questionnaire flags and scores, and low mood in the last 3 check-ins.\n'
          '2. RADR: watch data away from the person\'s own usual and not yet marked as reviewed, more areas first. It orders your '
          'list; it is not an alert, and it never comes before an answer waiting for review.\n'
          '3. Other things, such as no check-in for a few days.\n'
          '4. Everyone else, by name. Patients marked as stable are at the bottom.\n\n'
          'Flags and RADR help you review. They are not a diagnosis or a risk score, and nobody watches them around the clock.',
          style: context.tt.bodySmall?.copyWith(color: context.sc.ink2, height: 1.4),
        ),
      ]);
}

Future<void> showListOrder(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => const SafeArea(child: Padding(padding: EdgeInsets.fromLTRB(20, 0, 20, 24), child: ListOrderNote())),
    );

/// Why [p] is where they are in the list: the reason in plain words, what is waiting, and the
/// RADR flags to open.
Future<void> showWhyHere(BuildContext context, PatientSummary p, {VoidCallback? onChanged}) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) {
        final radr = p.radr;
        final radrFlags = radr != null && radr.level != 'none' && !p.stable ? radr.flags : const <RadrFlag>[];
        final open = p.flags.where((f) => f.reviewable && f.reviewed == null).toList();
        return SafeArea(
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.6,
            maxChildSize: 0.95,
            builder: (c, scroll) => ListView(controller: scroll, padding: const EdgeInsets.fromLTRB(20, 0, 20, 24), children: [
              Text('Why ${p.name} is here', style: c.tt.titleLarge),
              const SizedBox(height: 8),
              Text(p.whyHere.isEmpty ? 'Nothing waiting for review.' : p.whyHere),
              if (open.isNotEmpty) ...[
                const SizedBox(height: 8),
                const SectionHeader('Answers waiting for review'),
                Wrap(spacing: 6, runSpacing: 6, children: [for (final f in open) FlagChip(f.label, p.stable ? Severity.none : f.severity)]),
                const SizedBox(height: 4),
                Text('Open ${p.name} to mark these as reviewed.', style: c.tt.bodySmall?.copyWith(color: c.sc.ink3)),
              ],
              if (radrFlags.isNotEmpty) ...[
                const SizedBox(height: 8),
                SectionHeader('RADR on ${radrDay(radr?.day ?? '')}'),
                for (final f in radrFlags) RadrFlagTile(patientId: p.id, flag: f, onChanged: onChanged),
              ],
              const SizedBox(height: 8),
              const ListOrderNote(),
            ]),
          ),
        );
      },
    );
