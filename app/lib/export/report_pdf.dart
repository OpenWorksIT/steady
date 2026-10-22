// SPDX-License-Identifier: AGPL-3.0-or-later
// A patient's Steady record as a PDF report: check-in trends, questionnaire scores, the RADR
// research view, exercises, watch data and the patient's notes. Built on the device; nothing is
// sent anywhere else.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'export_data.dart';

/* ---------- look ---------- */

const _ink = PdfColor.fromInt(0xFF1F2A33);
const _ink2 = PdfColor.fromInt(0xFF5B6770);
const _ink3 = PdfColor.fromInt(0xFF8A969E);
const _line = PdfColor.fromInt(0xFFDCE3E7);
const _soft = PdfColor.fromInt(0xFFF3F6F8);
const _brand = PdfColor.fromInt(0xFF2C5F7C);
const _brandSoft = PdfColor.fromInt(0xFFE4ECF1);
const _accent = PdfColor.fromInt(0xFFB0690C);
const _accentSoft = PdfColor.fromInt(0xFFFBF1E2);
const _alert = PdfColor.fromInt(0xFFA2352B);
const _warn = PdfColor.fromInt(0xFF8A570C);
const _calm = PdfColor.fromInt(0xFF4F7A4B);
const _white = PdfColors.white;

const _scaleColours = {
  'mood': PdfColor.fromInt(0xFF2C5F7C),
  'anxiety': PdfColor.fromInt(0xFFC0602B),
  'sleep': PdfColor.fromInt(0xFF6A5ACD),
  'energy': PdfColor.fromInt(0xFF3C8D5A),
};
const _scaleNames = {'mood': 'Mood', 'anxiety': 'Anxiety', 'sleep': 'Sleep', 'energy': 'Energy'};

PdfColor _severity(String s) => switch (s) {
      'alert' => _alert,
      'warn' => _warn,
      'info' => _brand,
      _ => _ink2,
    };

const _small = pw.TextStyle(fontSize: 8, color: _ink2);
const _body = pw.TextStyle(fontSize: 9, color: _ink, lineSpacing: 1.5);

Future<Uint8List> buildPdfReport(ExportBundle bundle, ExportPatient p) async {
  final base = pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans.ttf'));
  final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans-Bold.ttf'));
  pw.MemoryImage? logo;
  try {
    logo = pw.MemoryImage((await rootBundle.load('assets/brand/mark.png')).buffer.asUint8List());
  } catch (_) {
    logo = null;
  }
  final doc = pw.Document(
    theme: pw.ThemeData.withFont(base: base, bold: bold),
    title: 'Steady report: ${p.name}',
    author: bundle.clinician,
    creator: 'Steady (OpenWorks IT)',
  );
  final range = '${p.from == null ? '' : _date(p.from!)} to ${p.to == null ? '' : _date(p.to!)}';

  doc.addPage(pw.MultiPage(
    pageTheme: const pw.PageTheme(pageFormat: PdfPageFormat.a4, margin: pw.EdgeInsets.fromLTRB(40, 34, 40, 34)),
    header: (ctx) => ctx.pageNumber == 1
        ? pw.SizedBox()
        : pw.Container(
            margin: const pw.EdgeInsets.only(bottom: 14),
            padding: const pw.EdgeInsets.only(bottom: 6),
            decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: _line, width: 0.6))),
            child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
              pw.Text(p.name, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: _ink)),
              pw.Text('Steady report · $range', style: _small),
            ]),
          ),
    footer: (ctx) => pw.Container(
      margin: const pw.EdgeInsets.only(top: 12),
      padding: const pw.EdgeInsets.only(top: 6),
      decoration: const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(color: _line, width: 0.6))),
      child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text('${bundle.practice} · Confidential health information · flags and RADR are review aids, not a diagnosis',
            style: const pw.TextStyle(fontSize: 6.5, color: _ink3)),
        pw.Text('${ctx.pageNumber} / ${ctx.pagesCount}', style: const pw.TextStyle(fontSize: 7, color: _ink3)),
      ]),
    ),
    build: (ctx) => [
      _cover(bundle, p, range, logo),
      ..._summary(p),
      ..._checkinTrend(p),
      ..._assessments(p),
      ..._radr(p),
      ..._wearable(p),
      ..._exercises(p),
      ..._notes(p),
    ],
  ));
  return doc.save();
}

String _two(int n) => n.toString().padLeft(2, '0');
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String _date(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';
String _dateTime(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}, ${_two(d.hour)}:${_two(d.minute)}';
String _short(DateTime d) => '${d.day} ${_months[d.month - 1]}';

/* ---------- building blocks ---------- */

pw.Widget _cover(ExportBundle bundle, ExportPatient p, String range, pw.MemoryImage? logo) {
  pw.Widget meta(String label, String value) => pw.Expanded(
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text(label.toUpperCase(), style: const pw.TextStyle(fontSize: 6.5, color: _ink3, letterSpacing: 0.8)),
          pw.SizedBox(height: 2),
          pw.Text(value, style: const pw.TextStyle(fontSize: 9, color: _ink)),
        ]),
      );
  return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
    pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: pw.BoxDecoration(color: _brand, borderRadius: pw.BorderRadius.circular(8)),
      child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
        if (logo != null) ...[
          pw.Container(
            width: 42,
            height: 42,
            padding: const pw.EdgeInsets.all(5),
            decoration: const pw.BoxDecoration(color: _white, shape: pw.BoxShape.circle),
            child: pw.Image(logo, fit: pw.BoxFit.contain),
          ),
          pw.SizedBox(width: 12),
        ],
        pw.Expanded(
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text(bundle.practice.toUpperCase(), style: pw.TextStyle(fontSize: 11, color: _white, fontWeight: pw.FontWeight.bold, letterSpacing: 1.2)),
            pw.SizedBox(height: 2),
            pw.Text('Steady · between-session record', style: const pw.TextStyle(fontSize: 9, color: PdfColor.fromInt(0xFFD6E3EB))),
          ]),
        ),
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: pw.BoxDecoration(border: pw.Border.all(color: _white, width: 0.8), borderRadius: pw.BorderRadius.circular(10)),
          child: pw.Text('CONFIDENTIAL', style: pw.TextStyle(fontSize: 7, color: _white, fontWeight: pw.FontWeight.bold, letterSpacing: 1)),
        ),
      ]),
    ),
    pw.SizedBox(height: 18),
    pw.Text(p.name, style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold, color: _ink)),
    if (p.selfName.isNotEmpty && p.selfName != p.name) ...[
      pw.SizedBox(height: 2),
      pw.Text('Calls themselves ${p.selfName} in the app', style: const pw.TextStyle(fontSize: 10, color: _ink2)),
    ],
    pw.SizedBox(height: 12),
    pw.Container(
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(color: _soft, borderRadius: pw.BorderRadius.circular(6)),
      child: pw.Row(children: [
        meta('Period', range),
        meta('Joined Steady', p.joinedAt == null ? '-' : _date(p.joinedAt!)),
        meta('Access', p.active ? 'Active' : 'Stopped'),
        meta('Prepared', '${bundle.clinician}, ${_dateTime(bundle.generatedAt)}'),
      ]),
    ),
  ]);
}

/// Widgets that stay on one page together (a heading is never left alone at the foot of a page).
/// Containers and Columns pass page breaks through to their children; a Stack is never split.
pw.Widget _keep(List<pw.Widget> children) =>
    pw.Stack(children: [pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: children)]);

pw.Widget _section(String title, [String? caption]) => pw.Padding(
      padding: const pw.EdgeInsets.only(top: 20, bottom: 8),
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Row(children: [
          pw.Container(width: 3, height: 13, decoration: pw.BoxDecoration(color: _accent, borderRadius: pw.BorderRadius.circular(1.5))),
          pw.SizedBox(width: 7),
          pw.Text(title, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, color: _ink)),
        ]),
        if (caption != null) ...[
          pw.SizedBox(height: 3),
          pw.Padding(padding: const pw.EdgeInsets.only(left: 10), child: pw.Text(caption, style: _small)),
        ],
      ]),
    );

pw.Widget _muted(String text) => pw.Text(text, style: _small);

/// A rounded, tinted box with a coloured strip down its left edge (the PDF library can't round
/// a border that differs per side, so the strip is its own box, clipped by the rounded corners).
pw.Widget _stripBox({required PdfColor colour, required PdfColor background, required pw.Widget child, double? width}) => pw.SizedBox(
      width: width,
      child: pw.ClipRRect(
        horizontalRadius: 6,
        verticalRadius: 6,
        child: pw.Stack(children: [
          pw.Container(
            width: width,
            color: background,
            padding: const pw.EdgeInsets.fromLTRB(12, 8, 9, 8),
            child: child,
          ),
          pw.Positioned(left: 0, top: 0, bottom: 0, child: pw.Container(width: 3, color: colour)),
        ]),
      ),
    );

pw.Widget _card(String value, String label, {PdfColor colour = _brand}) => _stripBox(
      width: 120,
      colour: colour,
      background: _soft,
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text(value, style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold, color: _ink)),
        pw.SizedBox(height: 1),
        pw.Text(label, style: const pw.TextStyle(fontSize: 7.5, color: _ink2)),
      ]),
    );

/// A table with a tinted header, light zebra rows and room to breathe.
pw.Widget _table(List<String> headers, List<List<pw.Widget>> rows, {Map<int, pw.TableColumnWidth>? widths}) => pw.Table(
      columnWidths: widths,
      border: const pw.TableBorder(bottom: pw.BorderSide(color: _line, width: 0.6)),
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: _brandSoft),
          children: [
            for (final h in headers)
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                child: pw.Text(h, style: pw.TextStyle(fontSize: 7.5, fontWeight: pw.FontWeight.bold, color: _brand)),
              ),
          ],
        ),
        for (var i = 0; i < rows.length; i++)
          pw.TableRow(
            decoration: pw.BoxDecoration(color: i.isOdd ? _soft : _white),
            children: [for (final c in rows[i]) pw.Padding(padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4), child: c)],
          ),
      ],
    );

pw.Widget _cell(String text, {PdfColor colour = _ink, bool bold = false}) =>
    pw.Text(text, style: pw.TextStyle(fontSize: 8, color: colour, fontWeight: bold ? pw.FontWeight.bold : null));

String _avg(Iterable<num> xs) => xs.isEmpty ? '-' : (xs.reduce((a, b) => a + b) / xs.length).toStringAsFixed(1);

/* ---------- sections ---------- */

List<pw.Widget> _summary(ExportPatient p) => [
      _section('At a glance'),
      pw.Wrap(spacing: 8, runSpacing: 8, children: [
        _card('${p.checkins.length}', 'check-ins'),
        for (final k in _scaleNames.keys)
          _card(_avg(p.checkins.map((c) => c.scale(k))), '${_scaleNames[k]!.toLowerCase()}, average of 5', colour: _scaleColours[k]!),
        _card('${p.assessments.length}', 'questionnaires completed', colour: _accent),
        _card('${p.exercises.length}', 'exercises done', colour: _calm),
        if (p.wearableDays.isNotEmpty) _card('${p.wearableDays.length}', 'days of watch data', colour: _ink2),
      ]),
      if (p.flags.isNotEmpty) ...[
        pw.SizedBox(height: 10),
        pw.Container(
          padding: const pw.EdgeInsets.all(9),
          decoration: pw.BoxDecoration(color: _accentSoft, borderRadius: pw.BorderRadius.circular(6)),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('Review flags at the end of the period', style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: _warn)),
            pw.SizedBox(height: 3),
            for (final f in p.flags) pw.Text('•  ${f.label}', style: pw.TextStyle(fontSize: 8.5, color: _severity(f.severity))),
          ]),
        ),
      ],
    ];

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

/// 1, 2, 2.5 or 5 times a power of ten: tick steps that read well on an axis.
double _niceStep(double raw) {
  if (raw <= 1) return 1;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  for (final m in [1.0, 2.0, 2.5, 5.0, 10.0]) {
    if (raw <= m * mag) return m * mag;
  }
  return 10 * mag;
}

pw.Widget _legend(Map<String, (PdfColor, List<double?>)> series) => pw.Padding(
      padding: const pw.EdgeInsets.only(left: 18, bottom: 4),
      child: pw.Row(children: [
        for (final e in series.entries) ...[
          pw.Container(width: 9, height: 2.4, color: e.value.$1),
          pw.SizedBox(width: 4),
          pw.Text(e.key, style: const pw.TextStyle(fontSize: 7, color: _ink2)),
          pw.SizedBox(width: 12),
        ],
      ]),
    );

pw.Widget _chart(List<DateTime> xs, Map<String, (PdfColor, List<double?>)> series,
    {required double min, required double max, String Function(num)? yFormat, double height = 150, bool fill = true}) {
  final drawn = {
    for (final e in series.entries)
      if (e.value.$2.whereType<double>().isNotEmpty) e.key: e.value,
  };
  if (xs.length < 2 || drawn.isEmpty) return _muted('Not enough data for a chart yet.');
  final every = (xs.length / 7).ceil().clamp(1, 1000);
  final labels = [for (var i = 0; i < xs.length; i++) i % every == 0 ? _short(xs[i]) : ''];
  final span = max - min <= 0 ? 1.0 : max - min;
  final stepY = _niceStep(span / 5);
  min = (min / stepY).floorToDouble() * stepY;
  final ticks = <double>[];
  for (var v = min; ; v += stepY) {
    ticks.add(v);
    if (v >= max) break;
  }
  final top = ticks.last;
  final dense = xs.length > 45;
  final chart = pw.Container(
    height: height - (drawn.length > 1 ? 14 : 0),
    padding: const pw.EdgeInsets.only(top: 4),
    child: pw.Chart(
      grid: pw.CartesianGrid(
        xAxis: pw.FixedAxis.fromStrings(labels,
            marginStart: 14, marginEnd: 14, ticks: true, color: _line, textStyle: const pw.TextStyle(fontSize: 6.5, color: _ink3)),
        yAxis: pw.FixedAxis(ticks,
            divisions: true, divisionsColor: _line, divisionsWidth: 0.4, color: _line,
            format: yFormat ?? (v) => v.toStringAsFixed(0), textStyle: const pw.TextStyle(fontSize: 6.5, color: _ink3)),
      ),
      datasets: [
        for (final (i, e) in drawn.entries.indexed)
          pw.LineDataSet(
            legend: e.key,
            color: e.value.$1,
            drawSurface: fill && i == 0,
            surfaceColor: e.value.$1,
            surfaceOpacity: 0.10,
            isCurved: !dense,
            smoothness: 0.25,
            drawPoints: !dense,
            pointSize: 1.8,
            lineWidth: 1.6,
            data: [
              for (var j = 0; j < e.value.$2.length; j++)
                if (e.value.$2[j] != null) pw.PointChartValue(j.toDouble(), e.value.$2[j]!.clamp(min, top).toDouble()),
            ],
          ),
      ],
    ),
  );
  return drawn.length > 1 ? _keep([_legend(drawn), chart]) : chart;
}

List<pw.Widget> _checkinTrend(ExportPatient p) {
  if (p.checkins.isEmpty) return [_section('Check-ins'), _muted('No check-ins in this period.')];
  final from = p.from ?? p.checkins.first.at, to = p.to ?? p.checkins.last.at;
  final buckets = {
    for (final k in _scaleNames.keys) k: _buckets<ExportCheckin>(p.checkins, (c) => c.at, (c) => c.scale(k).toDouble(), from, to),
  };
  final xs = buckets['mood']!.map((b) => b.start).toList();
  final weekly = to.difference(from).inDays + 1 > 120;
  List<double?> vals(String k) => buckets[k]!.map((b) => b.value).toList();
  return [
    _keep([
      _section('Check-ins', '${weekly ? 'Weekly' : 'Daily'} averages from 1 (low) to 5 (high). For anxiety, higher means more anxious.'),
      _chart(xs, {'Mood': (_scaleColours['mood']!, vals('mood')), 'Anxiety': (_scaleColours['anxiety']!, vals('anxiety'))}, min: 1, max: 5),
    ]),
    pw.SizedBox(height: 12),
    _chart(xs, {'Sleep': (_scaleColours['sleep']!, vals('sleep')), 'Energy': (_scaleColours['energy']!, vals('energy'))}, min: 1, max: 5),
  ];
}

List<pw.Widget> _assessments(ExportPatient p) {
  if (p.assessments.isEmpty) return [];
  final byKey = <String, List<ExportAssessment>>{};
  for (final a in p.assessments) {
    byKey.putIfAbsent(a.key, () => []).add(a);
  }
  final out = <pw.Widget>[_section('Questionnaires', 'Scores worked out by Steady from the patient\'s answers.')];
  final charts = <pw.Widget>[];
  for (final list in byKey.values) {
    final withScore = list.where((a) => a.total != null).toList();
    if (withScore.length >= 2 && withScore.first.max != null) {
      charts.add(pw.Container(
        width: 250,
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text(list.first.name, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: _ink)),
          _chart(withScore.map((a) => a.at).toList(), {list.first.name: (_accent, withScore.map((a) => a.total).toList())},
              min: 0, max: withScore.first.max!, height: 110),
        ]),
      ));
    }
  }
  if (charts.isNotEmpty) {
    out[0] = _keep([out[0], pw.Wrap(spacing: 14, runSpacing: 10, children: charts)]);
    out.add(pw.SizedBox(height: 12));
  }
  out.add(_table(
    ['Date', 'Questionnaire', 'Score', 'Band', 'Flags'],
    [
      for (final a in p.assessments.reversed)
        [
          _cell(_dateTime(a.at)),
          _cell(a.name, bold: true),
          _cell(a.total == null ? '-' : '${_n(a.total!)} / ${_n(a.max ?? 0)}'),
          _cell(a.band, colour: _severity(a.severity), bold: a.severity == 'alert' || a.severity == 'warn'),
          _cell(a.flags.map((f) => f.label).join('; '), colour: a.flags.isEmpty ? _ink : _alert),
        ],
    ],
    widths: {0: const pw.FixedColumnWidth(88), 1: const pw.FixedColumnWidth(70), 2: const pw.FixedColumnWidth(44), 3: const pw.FixedColumnWidth(80)},
  ));
  return out;
}

/* ---------- RADR ---------- */

PdfColor _heat(double? v) {
  if (v == null) return const PdfColor.fromInt(0xFFEEF1F3);
  if (v >= 1.5) {
    final t = ((v - 1.5) / 2.5).clamp(0.0, 1.0);
    return PdfColor(0.85 - 0.22 * t, 0.55 - 0.35 * t, 0.50 - 0.33 * t);
  }
  final t = (v / 1.5).clamp(0.0, 1.0);
  return PdfColor(0.89 - 0.33 * t, 0.93 - 0.30 * t, 0.95 - 0.24 * t);
}

List<pw.Widget> _radr(ExportPatient p) {
  final r = p.radr;
  if (r == null) return [];
  final rated = r.rated;
  final out = <pw.Widget>[
    _section('RADR · Research Amon Dîn Rating',
        'How far the watch data and check-ins are from this person\'s own normal, 0 (usual) to 4 (far from usual).'),
    _stripBox(
      width: double.infinity,
      colour: _accent,
      background: _accentSoft,
      child: pw.Text(
        'For research only: not a risk score, prediction or diagnosis, and not monitored around the clock. Each measure is '
        'compared with the person\'s previous four weeks; four domains are scored and shown with the check-ins beside them. '
        'Method and sources: docs/RADR.md in the Steady repository.',
        style: const pw.TextStyle(fontSize: 8, color: _ink, lineSpacing: 1.4),
      ),
    ),
    pw.SizedBox(height: 10),
  ];
  if (rated.isEmpty) {
    out.add(_muted('Not enough watch data yet: RADR starts once there are about three weeks of nights to compare with.'));
    return out;
  }
  final last = r.latest ?? rated.last;
  String f(double? v) => v == null ? '-' : v.toStringAsFixed(1);
  out.add(pw.Wrap(spacing: 8, runSpacing: 8, children: [
    _card(f(last.watch), 'watch index (${_short(last.day)})', colour: _brand),
    _card('${last.convergent} of 4', 'domains away from usual', colour: last.convergent >= 2 ? _alert : _calm),
    _card(f(last.self), 'check-in score', colour: _scaleColours['anxiety']!),
    _card(f(last.combined), 'combined', colour: _ink2),
  ]));
  final head = _keep(List.of(out));
  out
    ..clear()
    ..add(head);
  out.add(pw.SizedBox(height: 10));

  // latest domain bars
  out.add(pw.Column(children: [
    for (final k in ExportRadr.domainKeys)
      pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 4),
        child: pw.Row(children: [
          pw.SizedBox(width: 70, child: pw.Text(ExportRadr.domainNames[k]!, style: const pw.TextStyle(fontSize: 8.5, color: _ink))),
          pw.Expanded(child: _bar(last.domains[k])),
          pw.SizedBox(
            width: 70,
            child: pw.Text(
              last.domains[k] == null
                  ? 'no data'
                  : '${f(last.domains[k])}${k == 'circadian' && r.shift.isNotEmpty && (last.domains[k] ?? 0) >= 1 ? ' (${r.shift})' : ''}',
              textAlign: pw.TextAlign.right,
              style: const pw.TextStyle(fontSize: 8, color: _ink2),
            ),
          ),
        ]),
      ),
  ]));

  // watch index and check-in score over time
  out.add(pw.SizedBox(height: 6));
  out.add(_chart(r.days.map((d) => d.day).toList(), {
    'Watch index': (_brand, r.days.map((d) => d.watch).toList()),
    'Check-in score': (_scaleColours['anxiety']!, r.days.map((d) => d.self).toList()),
  }, min: 0, max: 4, height: 140));

  // domains by day
  out.add(pw.SizedBox(height: 10));
  out.add(pw.Text('By domain, each mark a day (darker red: further from usual)', style: _small));
  out.add(pw.SizedBox(height: 4));
  out.add(pw.Column(children: [
    for (final k in ExportRadr.domainKeys)
      pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 2),
        child: pw.Row(children: [
          pw.SizedBox(width: 70, child: pw.Text(ExportRadr.domainNames[k]!, style: const pw.TextStyle(fontSize: 7.5, color: _ink2))),
          pw.Expanded(
            child: pw.Row(children: [
              for (final d in r.days)
                pw.Expanded(child: pw.Container(height: 9, margin: const pw.EdgeInsets.only(right: 0.4), color: _heat(d.domains[k]))),
            ]),
          ),
        ]),
      ),
    pw.Row(children: [
      pw.SizedBox(width: 70),
      pw.Expanded(child: pw.Text(_short(r.days.first.day), style: const pw.TextStyle(fontSize: 6.5, color: _ink3))),
      pw.Text(_short(r.days.last.day), style: const pw.TextStyle(fontSize: 6.5, color: _ink3)),
    ]),
  ]));

  // concordance
  out.add(pw.SizedBox(height: 10));
  out.add(pw.Text('Does the watch move with the check-ins? (rank correlation, watch ahead by 0 to 3 days)', style: _small));
  out.add(pw.SizedBox(height: 4));
  out.add(pw.SizedBox(
    width: 300,
    child: _table(
      ['Watch ahead by', 'Correlation', 'Days'],
      [
        for (final c in r.concordance)
          [
            _cell(c.lag == 0 ? 'Same day' : '${c.lag} day${c.lag == 1 ? '' : 's'}'),
            _cell(c.rho == null ? 'too few days' : c.rho!.toStringAsFixed(2), bold: (c.rho ?? 0) >= 0.5),
            _cell('${c.n}'),
          ],
      ],
    ),
  ));
  out.add(pw.SizedBox(height: 4));
  out.add(_muted('Watch data on ${r.wearDays} days and check-ins on ${r.checkinDays} days of the ${r.days.length} shown.'));
  return out;
}

/// A 0..4 bar: filled part in brand blue, red from 1.5 ("away from usual").
pw.Widget _bar(double? value) {
  final filled = (((value ?? 0).clamp(0, 4)) / 4 * 1000).round();
  return pw.Container(
    height: 7,
    decoration: pw.BoxDecoration(color: _soft, borderRadius: pw.BorderRadius.circular(3.5)),
    child: pw.Row(children: [
      if (filled > 0)
        pw.Expanded(
          flex: filled,
          child: pw.Container(
            decoration: pw.BoxDecoration(color: (value ?? 0) >= 1.5 ? _alert : _brand, borderRadius: pw.BorderRadius.circular(3.5)),
          ),
        ),
      if (filled < 1000) pw.Expanded(flex: 1000 - filled, child: pw.SizedBox()),
    ]),
  );
}

/* ---------- the rest ---------- */

List<pw.Widget> _wearable(ExportPatient p) {
  if (p.wearableDays.isEmpty) return [];
  final days = p.wearableDays.map((d) => DateTime.tryParse(d.day) ?? DateTime(1970)).toList();
  double? v(int i, String k) => (p.wearableDays[i].values[k] as num?)?.toDouble();
  final charts = <pw.Widget>[];
  void add(String key, String title, PdfColor colour, {double Function(double)? map, String unit = ''}) {
    final vals = [for (var i = 0; i < days.length; i++) v(i, key) == null ? null : (map ?? (x) => x)(v(i, key)!)];
    final present = vals.whereType<double>().toList();
    if (present.length < 2) return;
    final lo = present.reduce((a, b) => a < b ? a : b), hi = present.reduce((a, b) => a > b ? a : b);
    final pad = ((hi - lo) * 0.15).clamp(1, 1e9).toDouble();
    final avg = present.reduce((a, b) => a + b) / present.length;
    charts.add(pw.Container(
      width: 250,
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text('$title${unit.isEmpty ? '' : ' ($unit)'}', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: _ink)),
          pw.Text('average ${avg >= 100 ? avg.round() : avg.toStringAsFixed(1)}', style: _small),
        ]),
        _chart(days, {title: (colour, vals)}, min: (lo - pad).floorToDouble().clamp(0, 1e9).toDouble(), max: (hi + pad).ceilToDouble(), height: 110),
      ]),
    ));
  }

  add('rhr', 'Resting heart rate', _alert, unit: 'bpm');
  add('sleep_min', 'Sleep', _scaleColours['sleep']!, map: (m) => m / 60, unit: 'hours');
  add('steps', 'Steps', _calm);
  add('hr_avg', 'Average heart rate', _ink2, unit: 'bpm');
  if (charts.isEmpty) return [];
  return [
    _keep([
      _section('Watch data', 'Daily summaries the patient chose to share from their watch.'),
      pw.Wrap(spacing: 14, runSpacing: 12, children: charts),
    ]),
  ];
}

List<pw.Widget> _exercises(ExportPatient p) {
  if (p.exercises.isEmpty) return [];
  final counts = <String, int>{};
  for (final e in p.exercises) {
    counts[e.name] = (counts[e.name] ?? 0) + 1;
  }
  return [
    _section('Exercises'),
    _table(['Exercise', 'Times done', 'Last done'], [
      for (final e in counts.entries)
        [
          _cell(e.key, bold: true),
          _cell('${e.value}'),
          _cell(_dateTime(p.exercises.where((x) => x.name == e.key).map((x) => x.at).reduce((a, b) => a.isAfter(b) ? a : b))),
        ],
    ]),
  ];
}

List<pw.Widget> _notes(ExportPatient p) {
  final notes = p.checkins.where((c) => c.note.trim().isNotEmpty).toList();
  if (notes.isEmpty) return [];
  return [
    _section("The patient's own words", 'Notes added to check-ins, newest first.'),
    _table(['Date', 'Mood', 'Note'], [
      for (final c in notes.reversed)
        [
          _cell(_dateTime(c.at)),
          _cell('${c.mood} / 5', colour: c.mood <= 2 ? _alert : _ink),
          pw.Text(c.note.trim(), style: _body),
        ],
    ], widths: {0: const pw.FixedColumnWidth(88), 1: const pw.FixedColumnWidth(40)}),
  ];
}

String _n(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
