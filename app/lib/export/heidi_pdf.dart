// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A patient's Steady data as a text-first PDF for Heidi (the practice's AI scribe) to read as
// session context: how to read it, the data with dates, and what not to infer. Tested with
// Heidi on a fictional patient (Demo C): it kept to the wording and got the facts right.
//
// Exports can run in a series: "since the last export" files start with what the previous one
// covered, a short "how to read", and where things stood, then only the new days. RADR is still
// worked out on the full history (it needs the baselines); only the new days are printed.
// Built on the device; nothing is sent anywhere else.
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'export_data.dart';

/// The layout's version, printed in the file so a reader knows what to expect.
const kHeidiFormat = 'heidi-1';

enum HeidiKind { since, all, range }

const _ink = PdfColor.fromInt(0xFF1F2A33);
const _ink2 = PdfColor.fromInt(0xFF5B6770);
const _line = PdfColor.fromInt(0xFFB9C4CA);
const _soft = PdfColor.fromInt(0xFFF1F4F6);
const _brand = PdfColor.fromInt(0xFF2C5F7C);

const _months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
String _two(int n) => n.toString().padLeft(2, '0');
String _day(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';
String _dayShort(DateTime d) => '${d.day} ${_months[d.month - 1].substring(0, 3)}';
String _time(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';
String _isoDay(String s) {
  final d = DateTime.tryParse(s);
  return d == null ? s : _day(d);
}

String _hm(num? minutes) {
  if (minutes == null) return '-';
  final m = minutes.round();
  return '${m ~/ 60} h ${_two(m % 60)}';
}

String _clock(num? minutesFromMidnight) {
  if (minutesFromMidnight == null) return '-';
  final m = minutesFromMidnight.round() % 1440;
  return '${_two(m ~/ 60)}:${_two(m % 60)}';
}

String _exportedOn(HeidiMark m) {
  final at = m.at;
  return at == null ? 'an earlier date' : _day(at);
}

String _n1(double? v) => v == null ? '-' : v.toStringAsFixed(1);
String _n(num? v) => v == null ? '-' : (v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1));
double? _mean(Iterable<num> xs) => xs.isEmpty ? null : xs.reduce((a, b) => a + b) / xs.length;

const _scaleWords = {
  'mood': 'Mood (1 = very low, 5 = very good)',
  'anxiety': 'Anxiety or tension (1 = not at all, 5 = extremely; higher is worse)',
  'sleep': 'Last night\'s sleep (1 = very badly, 5 = very well)',
  'energy': 'Energy (1 = exhausted, 5 = full of energy)',
};

// questionnaires Steady ships with, described for the reader
const _known = {
  'phq9': 'PHQ-9 (depression symptoms over the last 2 weeks): 9 items, each 0 to 3, total 0 to 27. Bands: 0-4 minimal, 5-9 mild, '
      '10-14 moderate, 15-19 moderately severe, 20-27 severe. Item 9 asks about thoughts of being better off dead or of self-harm; '
      'any answer above 0 is flagged for the psychologist\'s review.',
  'gad7': 'GAD-7 (anxiety symptoms over the last 2 weeks): 7 items, each 0 to 3, total 0 to 21. Bands: 0-4 minimal, 5-9 mild, '
      '10-14 moderate, 15-21 severe.',
};

/// The Heidi-ready PDF. [kind] and [previous] say whether it continues a series.
Future<Uint8List> buildHeidiPdf(ExportBundle bundle, ExportPatient p, {required HeidiKind kind, HeidiMark? previous}) async {
  final base = pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans.ttf'));
  final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans-Bold.ttf'));
  final doc = pw.Document(
    theme: pw.ThemeData.withFont(base: base, bold: bold),
    title: 'Steady for Heidi: ${p.name}',
    author: bundle.clinician,
    creator: 'Steady (OpenWorks IT), $kHeidiFormat',
  );
  // the export this one continues from, if any
  final prev = kind == HeidiKind.since ? previous : null;
  final series = prev != null;
  final part = prev == null ? 1 : prev.part + 1;
  final radrVersion = p.radr?.version.isNotEmpty == true ? p.radr!.version : (p.methods['radr'] ?? '');
  final changedFrom = prev != null && prev.radr.isNotEmpty && radrVersion.isNotEmpty && prev.radr != radrVersion ? prev.radr : null;
  final from = p.from, to = p.to;
  final days = from == null || to == null ? 0 : to.difference(from).inDays + 1;

  doc.addPage(pw.MultiPage(
    pageTheme: const pw.PageTheme(pageFormat: PdfPageFormat.a4, margin: pw.EdgeInsets.fromLTRB(42, 36, 42, 36)),
    footer: (ctx) => pw.Padding(
      padding: const pw.EdgeInsets.only(top: 10),
      child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text('${bundle.practice} · Steady data for ${p.name} · confidential health information',
            style: const pw.TextStyle(fontSize: 7, color: _ink2)),
        pw.Text('${ctx.pageNumber} / ${ctx.pagesCount}', style: const pw.TextStyle(fontSize: 7, color: _ink2)),
      ]),
    ),
    build: (ctx) => [
      pw.Text('Steady: between-session data for ${p.name}', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold, color: _ink)),
      pw.SizedBox(height: 6),
      _meta([
        ('Patient', p.name),
        ('Period', '${from == null ? '' : _day(from)} to ${to == null ? '' : _day(to)} ($days day${days == 1 ? '' : 's'})'),
        ('Exported', '${_day(bundle.generatedAt)} at ${_time(bundle.generatedAt)}, by ${bundle.clinician}, from Steady (${bundle.practice}), format $kHeidiFormat'),
        ('Contains', [
          '${p.checkins.length} daily check-in${p.checkins.length == 1 ? '' : 's'}',
          '${p.assessments.length} questionnaire result${p.assessments.length == 1 ? '' : 's'}',
          if (p.wearableDays.isNotEmpty) '${p.wearableDays.length} days of watch summaries',
          if (p.radr != null && p.radr!.rated.isNotEmpty) 'RADR $radrVersion for each rated day',
          if (p.notes.isNotEmpty) '${p.notes.length} clinician note${p.notes.length == 1 ? '' : 's'}',
        ].join(', ')),
        if (prev != null) ('Series', 'Part $part. The previous export covered ${_isoDay(prev.from)} to ${_isoDay(prev.to)}, '
            'exported on ${_exportedOn(prev)}. This file adds only the days since then.'),
        if (kind == HeidiKind.all) ('Series', 'Everything from the start (part 1). Later exports can add only what\'s new.'),
        if (kind == HeidiKind.range) ('Note', 'Chosen dates: not part of the series of exports.'),
      ]),
      _box([
        _para('Tip for the clinician: in Heidi, link this session to the patient\'s profile, so this context carries forward to later '
            'sessions. Each new Steady file then simply adds to it.'),
      ]),
      if (changedFrom != null)
        _box([
          _para('The RADR method changed since the last export: $changedFrom then, $radrVersion now. Values in this file and the '
              'previous one are not directly comparable. "How to read" below describes the method used in this file.'),
        ]),

      ..._howToRead(p, short: series, radrVersion: radrVersion),
      if (series) ..._whereThingsStood(p),
      ..._summary(p),
      ..._flags(p),
      ..._questionnaires(p),
      ..._checkins(p),
      ..._watch(p),
      ..._radrDays(p, radrVersion),
      ..._notes(p),
      ..._notToInfer(),
      pw.SizedBox(height: 10),
      pw.Text('Steady is open-source software by OpenWorks IT. Export format $kHeidiFormat. '
          '${p.methods['steadyBuild']?.isNotEmpty == true ? 'Steady build ${p.methods['steadyBuild']}.' : ''}',
          style: const pw.TextStyle(fontSize: 7.5, color: _ink2)),
    ],
  ));
  return doc.save();
}

/* ---------- building blocks ---------- */

pw.Widget _h2(String t) => pw.Container(
      margin: const pw.EdgeInsets.only(top: 14, bottom: 5),
      padding: const pw.EdgeInsets.only(bottom: 2),
      decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: _brand, width: 1))),
      child: pw.Text(t, style: pw.TextStyle(fontSize: 12.5, fontWeight: pw.FontWeight.bold, color: _ink)),
    );

pw.Widget _h3(String t) => pw.Padding(
      padding: const pw.EdgeInsets.only(top: 7, bottom: 3),
      child: pw.Text(t, style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: _ink)),
    );

pw.Widget _para(String t) =>
    pw.Padding(padding: const pw.EdgeInsets.only(bottom: 4), child: pw.Text(t, style: const pw.TextStyle(fontSize: 9.4, color: _ink, lineSpacing: 1.6)));

pw.Widget _bullet(String t) => pw.Padding(
      padding: const pw.EdgeInsets.only(left: 8, bottom: 3),
      child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.SizedBox(width: 10, child: pw.Text('•', style: const pw.TextStyle(fontSize: 9.4))),
        pw.Expanded(child: pw.Text(t, style: const pw.TextStyle(fontSize: 9.4, color: _ink, lineSpacing: 1.5))),
      ]),
    );

pw.Widget _box(List<pw.Widget> children) => pw.Container(
      width: double.infinity,
      margin: const pw.EdgeInsets.only(top: 8),
      padding: const pw.EdgeInsets.all(8),
      decoration: pw.BoxDecoration(color: _soft, border: pw.Border.all(color: _line, width: 0.6)),
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: children),
    );

pw.Widget _meta(List<(String, String)> rows) => pw.Table(
      columnWidths: {0: const pw.FixedColumnWidth(62)},
      children: [
        for (final r in rows)
          pw.TableRow(children: [
            pw.Padding(padding: const pw.EdgeInsets.only(bottom: 2), child: pw.Text(r.$1, style: pw.TextStyle(fontSize: 9.4, fontWeight: pw.FontWeight.bold))),
            pw.Padding(padding: const pw.EdgeInsets.only(bottom: 2), child: pw.Text(r.$2, style: const pw.TextStyle(fontSize: 9.4))),
          ]),
      ],
    );

pw.Widget _table(List<String> head, List<List<String>> rows, {Map<int, pw.TableColumnWidth>? widths}) => pw.Table(
      border: pw.TableBorder.all(color: _line, width: 0.5),
      columnWidths: widths,
      children: [
        pw.TableRow(decoration: const pw.BoxDecoration(color: _soft), children: [
          for (final h in head) pw.Padding(padding: const pw.EdgeInsets.all(3), child: pw.Text(h, style: pw.TextStyle(fontSize: 8.4, fontWeight: pw.FontWeight.bold))),
        ]),
        for (final r in rows)
          pw.TableRow(children: [
            for (final c in r) pw.Padding(padding: const pw.EdgeInsets.all(3), child: pw.Text(c, style: const pw.TextStyle(fontSize: 8.4))),
          ]),
      ],
    );

/* ---------- sections ---------- */

List<pw.Widget> _howToRead(ExportPatient p, {required bool short, required String radrVersion}) {
  final keys = {for (final a in p.assessments) a.key, for (final b in p.before) b.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '')};
  final m = p.radr?.method ?? const {};
  final hasRadr = p.radr != null && p.radr!.rated.isNotEmpty;
  return [
    _h2(short ? '1. How to read this file (short version; part 1 of the series has the full one)' : '1. How to read this file'),
    _box([
      _para('For Heidi and the clinician. This file comes from Steady, a between-session check-in app. The patient used it at home '
          'between sessions; their psychologist sees the same data in the app. Use it as context for the session note: what the '
          'patient reported and what their watch recorded, with dates. Everything below is measured or reported data plus how it '
          'was calculated. It contains no diagnosis and no clinical judgement.'),
    ]),
    _h3('What was collected, and how'),
    _bullet('Daily check-in (by the patient, usually in the evening): four questions rated 1 to 5, and optional words in their own voice. '
        '${_scaleWords.values.join('. ')}.'),
    if (!short)
      for (final k in _known.keys)
        if (keys.contains(k)) _bullet(_known[k]!),
    if (short && keys.any(_known.containsKey)) _bullet('Questionnaires: ${keys.where(_known.containsKey).map((k) => k == 'phq9' ? 'PHQ-9 (total 0 to 27)' : 'GAD-7 (total 0 to 21)').join(', ')}; higher is more symptoms.'),
    if (keys.any((k) => !_known.containsKey(k)) && p.assessments.isNotEmpty)
      _bullet('Other questionnaires: as each one defines its scoring; the total and band are given with each result.'),
    if (p.wearableDays.isNotEmpty || p.wearableConnected)
      _bullet('Watch data (only because the patient chose to share it): a daily summary from Apple Health or Health Connect, worked out on '
          'the phone. Sleep: time asleep, when they fell asleep and woke, time awake in bed. Resting heart rate: the lowest 30-minute '
          'average during that night\'s sleep. Daily steps. Average blood oxygen. A missing day means the watch wasn\'t worn or didn\'t '
          'sync, not that nothing happened.'),
    if (hasRadr) ...[
      _h3('RADR (Research Amon Dîn Rating), version $radrVersion'),
      _para('RADR is a research view used by the practice to study whether watch data adds anything to what patients report. It is not a '
          'risk score, a prediction or a diagnosis, and nothing is triggered by it.'),
      if (!short) ...[
        _bullet('Each measure is averaged over ${m['smoothDays'] ?? 3} days and compared with the patient\'s own baseline: the '
            '${m['baselineDays'] ?? 28} days ending ${m['baselineGap'] ?? 7} days before (so a change that is building doesn\'t hide in its '
            'own baseline). A day is rated once the baseline holds ${m['baselineMin'] ?? 14} days of data.'),
        _bullet('Distance from usual is a robust z-score (median and median absolute deviation), counted only in the direction research '
            'links to decline, and capped at ${m['cap'] ?? 4}.'),
        _bullet('Four domains, each 0 to 4: Sleep (duration shorter or longer than usual; irregular nights), Body clock (sleep midpoint '
            'earlier or later), Activity (fewer steps), Heart (resting heart rate above usual).'),
        _bullet('Watch index = mean of the domains. Domains away from usual = how many are at ${m['notable'] ?? 1.5} or more on the same day '
            '(0 to 4). Check-in score (0 to 4): lower mood and energy, more anxiety, worse sleep, compared with the patient\'s own usual '
            'check-ins the same way. Combined = mean of watch index and check-in score.'),
        _bullet('Basis: Bernert et al. 2017 and Littlewood et al. 2019 (sleep irregularity and short sleep), Lim et al. 2024 (body clock '
            'shifts), Rykov et al. 2021 (combinations over single measures), Um et al. 2025 (heart measures). These studies used other '
            'watches and populations; RADR has not been validated in this practice.'),
      ] else
        _bullet('0 = as usual for this patient, 4 = far from usual, in four domains (sleep, body clock, activity, heart). "Away" = domains '
            'at ${m['notable'] ?? 1.5} or more on the same day.'),
      if (p.radr!.exclusions.isNotEmpty)
        _bullet('Switched off for this patient by their psychologist (still collected and shown, not counted): '
            '${p.radr!.exclusions.map((x) => '${ExportRadr.domainNames['${x['domain']}'] ?? x['domain']}${'${x['reason'] ?? ''}'.isEmpty ? '' : ' (${x['reason']})'}').join(', ')}.'),
    ],
  ];
}

List<pw.Widget> _whereThingsStood(ExportPatient p) {
  final f = p.radr?.startFeatures ?? const {};
  num? usual(String k) => (f[k] is Map ? (f[k] as Map)['usual'] : null) as num?;
  final lines = <String>[
    for (final b in p.before)
      'Latest ${b.name} before this period: ${_n(b.total)}${b.max == null ? '' : ' of ${_n(b.max)}'}${b.band.isEmpty ? '' : ' (${b.band.toLowerCase()})'}'
          '${b.at == null ? '' : ', on ${_day(b.at!)}'}.',
    if (usual('sleep_min') != null) 'Usual sleep at the start of this period: about ${_hm(usual('sleep_min'))} a night.',
    if (usual('rhr') != null) 'Usual resting heart rate: about ${_n(usual('rhr'))} bpm.',
    if (usual('steps') != null) 'Usual steps: about ${usual('steps')!.round()} a day.',
  ];
  return [
    _h2('Where things stood before this period'),
    if (lines.isEmpty) _para('Nothing recorded before this period.') else for (final l in lines) _bullet(l),
  ];
}

List<pw.Widget> _summary(ExportPatient p) {
  final c = p.checkins;
  final r = p.radr;
  final last = r == null ? null : (r.latest ?? (r.rated.isEmpty ? null : r.rated.last));
  final w = p.wearableDays;
  double? wv(String k) => _mean([for (final d in w) if (d.values[k] is num) d.values[k] as num]);
  return [
    _h2('Summary of the period'),
    _para('Averages over the period. No interpretation.'),
    _table(['Measure', 'Average', 'Days with data'], [
      for (final k in _scaleWords.keys) ['Check-in: ${_scaleWords[k]}', _n1(_mean(c.map((x) => x.scale(k)))), '${c.length}'],
      if (w.isNotEmpty) ...[
        ['Sleep duration', _hm(wv('sleep_min')), '${w.where((d) => d.values['sleep_min'] is num).length}'],
        ['Resting heart rate', wv('rhr') == null ? '-' : '${wv('rhr')!.round()} bpm', '${w.where((d) => d.values['rhr'] is num).length}'],
        ['Steps per day', wv('steps') == null ? '-' : '${wv('steps')!.round()}', '${w.where((d) => d.values['steps'] is num).length}'],
      ],
    ], widths: {0: const pw.FlexColumnWidth(3)}),
    for (final key in {for (final a in p.assessments) a.key})
      _bullet('${p.assessments.firstWhere((a) => a.key == key).name}: '
          '${p.assessments.where((a) => a.key == key).map((a) => '${_n(a.total)} (${_dayShort(a.at)})').join(', ')}.'),
    if (last != null)
      _bullet('RADR, latest rated day (${_day(last.day)}): watch index ${_n1(last.watch)} of 4; '
          '${ExportRadr.domainKeys.map((k) => '${ExportRadr.domainNames[k]} ${_n1(last.domains[k])}').join(', ')}; '
          '${last.convergent} of 4 domains away from usual.'),
  ];
}

List<pw.Widget> _flags(ExportPatient p) {
  final flags = p.flags.where((f) => f.reviewable).toList();
  if (flags.isEmpty) return [];
  return [
    _h2('Flags for the psychologist\'s review'),
    _para('Raised by Steady\'s rules (a screening answer, a high score, low mood in the last check-ins). Each says whether the psychologist '
        'has marked it as reviewed in Steady.'),
    for (final f in flags) _bullet('${f.label}${f.at == null ? '' : ' (${_day(f.at!)})'}: ${f.reviewText(_day)}.'),
  ];
}

List<pw.Widget> _questionnaires(ExportPatient p) {
  if (p.assessments.isEmpty) return [];
  return [
    _h2('Questionnaires'),
    _table(['Date', 'Questionnaire', 'Total', 'Band', 'Item answers'], [
      for (final a in p.assessments)
        [
          _day(a.at),
          a.name,
          '${_n(a.total)}${a.max == null ? '' : ' / ${_n(a.max)}'}',
          a.band,
          [
            for (final it in p.instruments[a.key]?.items ?? [for (final k in a.answers.keys) (id: k, text: '')])
              if (a.answers.containsKey(it.id)) '${it.id.replaceAll(RegExp(r'^[a-z0-9]+_'), '')}: ${a.answers[it.id]}',
          ].join(', '),
        ],
    ], widths: {0: const pw.FixedColumnWidth(70), 2: const pw.FixedColumnWidth(40)}),
    // the latest answers in words, so they can be quoted without looking up the scale
    for (final key in {for (final a in p.assessments) a.key}) ..._latestInWords(p, p.assessments.lastWhere((a) => a.key == key)),
  ];
}

List<pw.Widget> _latestInWords(ExportPatient p, ExportAssessment a) {
  final items = p.instruments[a.key]?.items ?? const [];
  if (items.isEmpty) return [];
  return [
    _h3('Latest ${a.name} answers in words (${_day(a.at)})'),
    _table(['Question', 'Answer'], [
      for (final it in items)
        if (a.answers.containsKey(it.id)) [it.text, '${p.answerLabel(a.key, it.id, a.answers[it.id])} (${a.answers[it.id]})'],
    ], widths: {0: const pw.FlexColumnWidth(3)}),
  ];
}

List<pw.Widget> _checkins(ExportPatient p) {
  if (p.checkins.isEmpty) return [];
  return [
    _h2('Daily check-ins'),
    _para('Mood, sleep and energy: higher is better. Anxiety: higher is worse.'),
    _table(['Date', 'Time', 'Mood', 'Anxiety', 'Sleep', 'Energy', 'In their own words'], [
      for (final c in p.checkins) [_day(c.at), _time(c.at), '${c.mood}', '${c.anxiety}', '${c.sleep}', '${c.energy}', c.note.trim()],
    ], widths: {0: const pw.FixedColumnWidth(78), 1: const pw.FixedColumnWidth(32), 6: const pw.FlexColumnWidth(3)}),
  ];
}

List<pw.Widget> _watch(ExportPatient p) {
  if (p.wearableDays.isEmpty) return [];
  String v(Map<String, dynamic> m, String k, String Function(num) f) => m[k] is num ? f(m[k] as num) : '-';
  return [
    _h2('Watch: daily summaries'),
    _para('Date = the day the night ended.'),
    _table(['Date', 'Asleep', 'Fell asleep', 'Woke', 'Awake in bed', 'Resting HR', 'Steps', 'Blood oxygen'], [
      for (final d in p.wearableDays)
        [
          _isoDay(d.day),
          v(d.values, 'sleep_min', _hm),
          v(d.values, 'sleep_onset', _clock),
          v(d.values, 'sleep_wake', _clock),
          v(d.values, 'sleep_awake', (x) => '${x.round()} min'),
          v(d.values, 'rhr', (x) => '${x.round()} bpm'),
          v(d.values, 'steps', (x) => '${x.round()}'),
          v(d.values, 'spo2_avg', (x) => '${_n(x)}%'),
        ],
    ], widths: {0: const pw.FixedColumnWidth(78)}),
  ];
}

List<pw.Widget> _radrDays(ExportPatient p, String version) {
  final rated = p.radr?.rated ?? const <ExportRadrDay>[];
  if (rated.isEmpty) return [];
  return [
    _h2('RADR by day ($version)'),
    _para('Domain scores 0 to 4 (0 = as usual for this patient, 4 = far from usual). Blank = not enough baseline yet or no data.'),
    _table(['Date', 'Sleep', 'Body clock', 'Activity', 'Heart', 'Watch index', 'Check-in score', 'Combined', 'Away'], [
      for (final d in rated)
        [
          _day(d.day),
          for (final k in ExportRadr.domainKeys) d.domains[k] == null ? '' : _n1(d.domains[k]),
          _n1(d.watch),
          _n1(d.self),
          _n1(d.combined),
          '${d.convergent}',
        ],
    ], widths: {0: const pw.FixedColumnWidth(78)}),
  ];
}

List<pw.Widget> _notes(ExportPatient p) => [
      _h2('Clinician notes'),
      if (p.notes.isEmpty)
        _para('No clinician notes were recorded in Steady for this period.')
      else
        _table(['Date', 'By', 'Note'], [
          for (final n in p.notes) [_day(n.at), n.by, n.text.trim()],
        ], widths: {0: const pw.FixedColumnWidth(78), 1: const pw.FixedColumnWidth(80)}),
    ];

List<pw.Widget> _notToInfer() => [
      _h2('What not to infer'),
      _bullet('Nothing in this file is a diagnosis, a risk assessment or a prediction. RADR is a research measure that has not been '
          'validated in this practice.'),
      _bullet('Do not describe RADR values as a "risk level" or "risk score" in the note. If mentioned, describe them as how far the '
          'patient\'s watch data and check-ins were from their own usual pattern.'),
      _bullet('A flagged screening answer (such as PHQ-9 item 9 above 0) needs the psychologist\'s own clinical assessment. The flags '
          'section says whether it was marked as reviewed in Steady; that mark is not a record of the assessment itself.'),
      _bullet('Watch data is approximate and depends on wear: missing days are missing data. Sleep stages and blood oxygen from consumer '
          'watches are estimates.'),
      _bullet('Check-in ratings are the patient\'s own momentary self-report, usually in the evening.'),
      _bullet('Combine this with what was said in the session; where they differ, the session takes precedence.'),
    ];
