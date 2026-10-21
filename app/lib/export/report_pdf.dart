// SPDX-License-Identifier: AGPL-3.0-or-later
// A patient's Steady record as a PDF report: check-in trends, questionnaire scores, exercises,
// watch data and the patient's notes. Built on the device; nothing is sent anywhere else.
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'export_data.dart';

const _ink = PdfColor.fromInt(0xFF1F2A33);
const _ink2 = PdfColor.fromInt(0xFF5B6770);
const _line = PdfColor.fromInt(0xFFD9DEE2);
const _scaleColours = {
  'mood': PdfColor.fromInt(0xFF2F6F8F),
  'anxiety': PdfColor.fromInt(0xFFC0602B),
  'sleep': PdfColor.fromInt(0xFF6A5ACD),
  'energy': PdfColor.fromInt(0xFF3C8D5A),
};
const _scaleNames = {'mood': 'Mood', 'anxiety': 'Anxiety', 'sleep': 'Sleep', 'energy': 'Energy'};

Future<Uint8List> buildPdfReport(ExportBundle bundle, ExportPatient p) async {
  final base = pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans.ttf'));
  final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans-Bold.ttf'));
  final doc = pw.Document(
    theme: pw.ThemeData.withFont(base: base, bold: bold),
    title: 'Steady report: ${p.name}',
    author: bundle.clinician,
    creator: 'Steady (OpenWorks IT)',
  );
  final range = '${p.from == null ? '' : dayText(p.from!)} to ${p.to == null ? '' : dayText(p.to!)}';

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.fromLTRB(40, 36, 40, 36),
    header: (ctx) => ctx.pageNumber == 1
        ? pw.SizedBox()
        : pw.Container(
            margin: const pw.EdgeInsets.only(bottom: 10),
            child: pw.Text('${p.name} · Steady report · $range', style: const pw.TextStyle(fontSize: 8, color: _ink2)),
          ),
    footer: (ctx) => pw.Container(
      margin: const pw.EdgeInsets.only(top: 10),
      child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text('Confidential health information. Flags are review aids, not a diagnosis or a risk score.',
            style: const pw.TextStyle(fontSize: 7, color: _ink2)),
        pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}', style: const pw.TextStyle(fontSize: 7, color: _ink2)),
      ]),
    ),
    build: (ctx) => [
      pw.Text(bundle.practice, style: const pw.TextStyle(fontSize: 10, color: _ink2)),
      pw.SizedBox(height: 4),
      pw.Text(p.name, style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold, color: _ink)),
      if (p.selfName.isNotEmpty && p.selfName != p.name)
        pw.Text('Calls themselves ${p.selfName} in the app', style: const pw.TextStyle(fontSize: 10, color: _ink2)),
      pw.SizedBox(height: 6),
      pw.Text(
        'Steady record, $range · joined ${p.joinedAt == null ? '-' : dayText(p.joinedAt!)}'
        '${p.active ? '' : ' · access stopped'} · prepared by ${bundle.clinician} on ${timeText(bundle.generatedAt)}',
        style: const pw.TextStyle(fontSize: 9, color: _ink2),
      ),
      pw.Divider(color: _line),
      ..._summary(p),
      ..._checkinTrend(p),
      ..._assessments(p),
      ..._exercises(p),
      ..._wearable(p),
      ..._notes(p),
    ],
  ));
  return doc.save();
}

pw.Widget _h(String text) => pw.Padding(
      padding: const pw.EdgeInsets.only(top: 14, bottom: 6),
      child: pw.Text(text, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, color: _ink)),
    );

pw.Widget _muted(String text) => pw.Text(text, style: const pw.TextStyle(fontSize: 9, color: _ink2));

String _avg(Iterable<num> xs) => xs.isEmpty ? '-' : (xs.reduce((a, b) => a + b) / xs.length).toStringAsFixed(1);

List<pw.Widget> _summary(ExportPatient p) {
  final cells = <(String, String)>[
    ('Check-ins', '${p.checkins.length}'),
    for (final k in _scaleNames.keys) ('${_scaleNames[k]} (avg)', _avg(p.checkins.map((c) => c.scale(k)))),
    ('Questionnaires', '${p.assessments.length}'),
    ('Exercises', '${p.exercises.length}'),
    if (p.wearableDays.isNotEmpty) ('Watch days', '${p.wearableDays.length}'),
  ];
  return [
    _h('Summary'),
    pw.Wrap(spacing: 8, runSpacing: 8, children: [
      for (final (label, value) in cells)
        pw.Container(
          width: 98,
          padding: const pw.EdgeInsets.all(8),
          decoration: pw.BoxDecoration(border: pw.Border.all(color: _line), borderRadius: pw.BorderRadius.circular(4)),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text(value, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: _ink)),
            pw.Text(label, style: const pw.TextStyle(fontSize: 8, color: _ink2)),
          ]),
        ),
    ]),
    if (p.flags.isNotEmpty) ...[
      pw.SizedBox(height: 8),
      _muted('Review flags at the end of this period: ${p.flags.map((f) => f.label).join('; ')}'),
    ],
  ];
}

/// Averages by day, or by week for long periods, keyed by the bucket's first day.
List<({DateTime start, double? value})> _buckets<T>(List<T> rows, DateTime Function(T) at, double? Function(T) value, DateTime from, DateTime to) {
  final days = to.difference(from).inDays + 1;
  final step = days > 120 ? 7 : 1;
  final start = DateTime(from.year, from.month, from.day);
  final n = (days / step).ceil().clamp(1, 1000);
  final sums = List<double>.filled(n, 0), counts = List<int>.filled(n, 0);
  for (final r in rows) {
    final v = value(r);
    if (v == null) continue;
    final d = at(r);
    final i = DateTime(d.year, d.month, d.day).difference(start).inDays ~/ step;
    if (i < 0 || i >= n) continue;
    sums[i] += v;
    counts[i]++;
  }
  return [for (var i = 0; i < n; i++) (start: start.add(Duration(days: i * step)), value: counts[i] == 0 ? null : sums[i] / counts[i])];
}

pw.Widget _chart(List<DateTime> xs, Map<String, (PdfColor, List<double?>)> series, {required double min, required double max, String Function(num)? yFormat}) {
  final drawn = {
    for (final e in series.entries)
      if (e.value.$2.whereType<double>().isNotEmpty) e.key: e.value,
  };
  if (xs.length < 2 || drawn.isEmpty) return _muted('Not enough data for a chart yet.');
  final every = (xs.length / 8).ceil().clamp(1, 1000);
  final labels = [for (var i = 0; i < xs.length; i++) i % every == 0 ? '${xs[i].day}/${xs[i].month}' : ''];
  final span = max - min <= 0 ? 1.0 : max - min;
  final stepY = span <= 5 ? 1.0 : (span / 5).ceilToDouble();
  final ticks = <double>[];
  for (var v = min; ; v += stepY) {
    ticks.add(v);
    if (v >= max) break;
  }
  max = ticks.last;
  series = drawn;
  return pw.SizedBox(
    height: 150,
    child: pw.Chart(
      grid: pw.CartesianGrid(
        xAxis: pw.FixedAxis.fromStrings(labels, marginStart: 12, marginEnd: 12, ticks: true, textStyle: const pw.TextStyle(fontSize: 7, color: _ink2)),
        yAxis: pw.FixedAxis(ticks, divisions: true, format: yFormat ?? (v) => v.toStringAsFixed(0), textStyle: const pw.TextStyle(fontSize: 7, color: _ink2)),
      ),
      overlay: series.length > 1 ? pw.ChartLegend(position: const pw.Alignment(-1, -1.3), direction: pw.Axis.horizontal) : null,
      datasets: [
        for (final e in series.entries)
          pw.LineDataSet(
            legend: e.key,
            color: e.value.$1,
            drawSurface: false,
            isCurved: false,
            pointSize: 2,
            lineWidth: 1.4,
            data: [
              for (var i = 0; i < e.value.$2.length; i++)
                if (e.value.$2[i] != null) pw.PointChartValue(i.toDouble(), e.value.$2[i]!.clamp(min, max).toDouble()),
            ],
          ),
      ],
    ),
  );
}

List<pw.Widget> _checkinTrend(ExportPatient p) {
  if (p.checkins.isEmpty) return [_h('Check-ins'), _muted('No check-ins in this period.')];
  final from = p.from ?? p.checkins.first.at, to = p.to ?? p.checkins.last.at;
  final buckets = {
    for (final k in _scaleNames.keys) k: _buckets<ExportCheckin>(p.checkins, (c) => c.at, (c) => c.scale(k).toDouble(), from, to),
  };
  final xs = buckets['mood']!.map((b) => b.start).toList();
  final weekly = to.difference(from).inDays + 1 > 120;
  return [
    _h('Check-ins'),
    _muted('${weekly ? 'Weekly' : 'Daily'} averages, 1 (low) to 5 (high). For anxiety, higher means more anxious.'),
    pw.SizedBox(height: 8),
    _chart(xs, {
      'Mood': (_scaleColours['mood']!, buckets['mood']!.map((b) => b.value).toList()),
      'Anxiety': (_scaleColours['anxiety']!, buckets['anxiety']!.map((b) => b.value).toList()),
    }, min: 1, max: 5),
    pw.SizedBox(height: 10),
    _chart(xs, {
      'Sleep': (_scaleColours['sleep']!, buckets['sleep']!.map((b) => b.value).toList()),
      'Energy': (_scaleColours['energy']!, buckets['energy']!.map((b) => b.value).toList()),
    }, min: 1, max: 5),
  ];
}

List<pw.Widget> _assessments(ExportPatient p) {
  if (p.assessments.isEmpty) return [];
  final byKey = <String, List<ExportAssessment>>{};
  for (final a in p.assessments) {
    byKey.putIfAbsent(a.key, () => []).add(a);
  }
  final out = <pw.Widget>[_h('Questionnaires')];
  for (final list in byKey.values) {
    final withScore = list.where((a) => a.total != null).toList();
    if (withScore.length >= 2 && withScore.first.max != null) {
      out.add(pw.Text(list.first.name, style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)));
      out.add(pw.SizedBox(height: 4));
      out.add(_chart(withScore.map((a) => a.at).toList(), {list.first.name: (_scaleColours['mood']!, withScore.map((a) => a.total).toList())},
          min: 0, max: withScore.first.max!));
      out.add(pw.SizedBox(height: 8));
    }
  }
  out.add(pw.TableHelper.fromTextArray(
    headers: ['Date', 'Questionnaire', 'Score', 'Band', 'Flags'],
    data: [
      for (final a in p.assessments)
        [
          timeText(a.at),
          a.name,
          a.total == null ? '-' : '${_n(a.total!)}/${_n(a.max ?? 0)}',
          a.band,
          a.flags.map((f) => f.label).join('; '),
        ],
    ],
    headerStyle: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
    cellStyle: const pw.TextStyle(fontSize: 8),
    headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF1F3F5)),
    border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: _line, width: 0.5)),
    columnWidths: {0: const pw.FixedColumnWidth(70), 2: const pw.FixedColumnWidth(40)},
  ));
  return out;
}

List<pw.Widget> _exercises(ExportPatient p) {
  if (p.exercises.isEmpty) return [];
  final counts = <String, int>{};
  for (final e in p.exercises) {
    counts[e.name] = (counts[e.name] ?? 0) + 1;
  }
  return [
    _h('Exercises'),
    pw.TableHelper.fromTextArray(
      headers: ['Exercise', 'Times done', 'Last done'],
      data: [
        for (final e in counts.entries)
          [e.key, '${e.value}', timeText(p.exercises.where((x) => x.name == e.key).map((x) => x.at).reduce((a, b) => a.isAfter(b) ? a : b))],
      ],
      headerStyle: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
      cellStyle: const pw.TextStyle(fontSize: 8),
      headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF1F3F5)),
      border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: _line, width: 0.5)),
    ),
  ];
}

List<pw.Widget> _wearable(ExportPatient p) {
  if (p.wearableDays.isEmpty) return [];
  final days = p.wearableDays.map((d) => DateTime.tryParse(d.day) ?? DateTime(1970)).toList();
  double? v(int i, String k) => (p.wearableDays[i].values[k] as num?)?.toDouble();
  final out = <pw.Widget>[_h('Watch data'), _muted('Daily summaries the patient chose to share from their watch.')];
  void add(String key, String title, {double Function(double)? map, String unit = ''}) {
    final vals = [for (var i = 0; i < days.length; i++) v(i, key) == null ? null : (map ?? (x) => x)(v(i, key)!)];
    final present = vals.whereType<double>().toList();
    if (present.length < 2) return;
    final lo = present.reduce((a, b) => a < b ? a : b), hi = present.reduce((a, b) => a > b ? a : b);
    final pad = ((hi - lo) * 0.15).clamp(1, 1e9).toDouble();
    out.add(pw.SizedBox(height: 8));
    out.add(pw.Text('$title${unit.isEmpty ? '' : ' ($unit)'}', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)));
    out.add(pw.SizedBox(height: 4));
    out.add(_chart(days, {title: (_scaleColours['mood']!, vals)}, min: (lo - pad).floorToDouble().clamp(0, 1e9).toDouble(), max: (hi + pad).ceilToDouble()));
  }

  add('rhr', 'Resting heart rate', unit: 'bpm');
  add('sleep_min', 'Sleep', map: (m) => m / 60, unit: 'hours');
  add('steps', 'Steps');
  return out;
}

List<pw.Widget> _notes(ExportPatient p) {
  final notes = p.checkins.where((c) => c.note.trim().isNotEmpty).toList();
  if (notes.isEmpty) return [];
  return [
    _h("The patient's own words"),
    _muted('Notes the patient added to their check-ins.'),
    pw.SizedBox(height: 6),
    pw.TableHelper.fromTextArray(
      headers: ['Date', 'Mood', 'Note'],
      data: [for (final c in notes) [timeText(c.at), '${c.mood}/5', c.note.trim()]],
      headerStyle: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
      cellStyle: const pw.TextStyle(fontSize: 8),
      headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF1F3F5)),
      border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: _line, width: 0.5)),
      columnWidths: {0: const pw.FixedColumnWidth(70), 1: const pw.FixedColumnWidth(32)},
    ),
  ];
}

String _n(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
