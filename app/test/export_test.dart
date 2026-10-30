// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:steady/export/export_data.dart';
import 'package:steady/export/heidi_pdf.dart';
import 'package:steady/export/report_pdf.dart';
import 'package:steady/export/workbook.dart';

Map<String, dynamic> sample({int days = 30}) {
  final start = DateTime.utc(2026, 9, 1, 18);
  return {
    'practice': 'VR Clinical Psychology',
    'clinician': 'Dr Démo',
    'generatedAt': '2026-10-21T10:00:00Z',
    'patients': [
      {
        'patient': {'id': 'p1', 'name': 'Megan A. (clinic)', 'selfName': 'Meg', 'joinedAt': '2026-08-01T09:00:00Z', 'active': true},
        'from': start.toIso8601String(),
        'to': start.add(Duration(days: days)).toIso8601String(),
        'checkins': [
          for (var i = 0; i < days; i += 2)
            {
              'at': start.add(Duration(days: i)).toIso8601String(),
              'mood': 1 + i % 5,
              'anxiety': 5 - i % 5,
              'sleep': 3,
              'energy': 2 + i % 3,
              'note': i == 4 ? 'Better than yesterday – slept well' : '',
            },
        ],
        'assessments': [
          for (var i = 0; i < 3; i++)
            {
              'at': start.add(Duration(days: i * 10)).toIso8601String(),
              'key': 'phq9',
              'name': 'PHQ-9',
              'total': 14 - i * 3,
              'max': 27,
              'band': 'Moderate',
              'severity': 'warn',
              'flags': i == 0 ? [{'label': 'Item 9 answered', 'severity': 'alert'}] : [],
              'answers': {'phq9_1': 2, 'phq9_9': i == 0 ? 1 : 0},
            },
        ],
        'instruments': {
          'phq9': {
            'name': 'PHQ-9',
            'items': [
              {'id': 'phq9_1', 'text': 'Little interest or pleasure in doing things'},
              {'id': 'phq9_9', 'text': 'Thoughts that you would be better off dead'},
            ],
            'responseSets': {
              'freq4': [
                {'label': 'Not at all', 'value': 0},
                {'label': 'Several days', 'value': 1},
                {'label': 'More than half the days', 'value': 2},
              ],
            },
          },
        },
        'exercises': [
          {'at': start.add(const Duration(days: 3)).toIso8601String(), 'key': 'box', 'name': 'Box breathing', 'selfStarted': true, 'minutes': 4},
        ],
        'flags': [{'label': 'Low mood on 3 of the last 5 check-ins', 'severity': 'warn'}],
        'radr': {
          'version': 'radr-1',
          'wearDays': days,
          'checkinDays': days ~/ 2,
          'concordance': [
            for (var l = 0; l < 4; l++) {'lag': l, 'n': 20, 'rho': l == 3 ? null : 0.6 - l * 0.1},
          ],
          'latest': {'day': '2026-09-30', 'watch': 2.4, 'self': 1.9, 'combined': 2.15, 'convergent': 3, 'shift': 'later',
            'domains': {'sleep': 3.1, 'circadian': 2.2, 'activity': 1.6, 'cardiac': 0.9}},
          'days': [
            for (var i = 0; i < days; i++)
              {
                'day': start.add(Duration(days: i)).toIso8601String().substring(0, 10),
                'watch': i < 14 ? null : (i % 4) * 0.7,
                'self': i < 14 ? null : 1.2,
                'combined': i < 14 ? null : 1.0,
                'convergent': i % 4,
                'domains': {'sleep': i < 14 ? null : (i % 5) * 0.8, 'circadian': 0.4, 'activity': null, 'cardiac': 1.7},
              },
          ],
        },
        'pending': 1,
        'wearable': {
          'connected': true,
          'days': [
            for (var i = 0; i < 10; i++)
              {'day': '2026-09-${(i + 1).toString().padLeft(2, '0')}', 'values': {'rhr': 60 + i, 'sleep_min': 400 + i * 5, 'steps': 5000 + i * 300}},
          ],
        },
      },
    ],
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the export is read into patients, check-ins, scores and answer labels', () {
    final b = ExportBundle.fromJson(sample());
    final p = b.patients.single;
    expect(p.name, 'Megan A. (clinic)');
    expect(p.checkins, hasLength(15));
    expect(p.assessments.first.total, 14);
    expect(p.answerLabel('phq9', 'phq9_1', 2), 'More than half the days');
    expect(p.radr!.rated.length, 16);
    expect(p.radr!.latest!.convergent, 3);
    expect(fileSafe('Megan A. (clinic)'), 'Megan-A-clinic');
  });

  test('the Excel workbook has a sheet per kind of data', () {
    final bytes = buildWorkbook(ExportBundle.fromJson(sample()));
    final x = Excel.decodeBytes(bytes);
    expect(x.tables.keys, containsAll(['About', 'Patients', 'Check-ins', 'Questionnaires', 'Answers', 'Exercises', 'Watch']));
    expect(x.tables['Check-ins']!.maxRows, 16);
    expect(x.tables['Answers']!.maxRows, 7);
    final answerRow = x.tables['Answers']!.rows[1].map((c) => c?.value?.toString() ?? '').toList();
    expect(answerRow, contains('Little interest or pleasure in doing things'));
    expect(x.tables['Watch']!.rows.first.map((c) => c?.value?.toString()), contains('Resting heart rate (bpm)'));
    expect(x.tables['RADR (research)']!.maxRows, 1 + 30 - 14);
  });

  test('the PDF report builds, for short and long periods', () async {
    for (final days in [1, 30, 200]) {
      final b = ExportBundle.fromJson(sample(days: days));
      final bytes = await buildPdfReport(b, b.patients.single);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-', reason: '$days days');
      expect(bytes.length, greaterThan(2000));
    }
  });

  // What 1.0 exports add: whether each flag was reviewed, the psychologist's notes, the methods,
  // where things stood before, and the Heidi series.
  Map<String, dynamic> clinical(Map<String, dynamic> raw) {
    final p = (raw['patients'] as List).first as Map<String, dynamic>;
    p['flags'] = [
      {'key': 'a:x1:f0', 'label': 'PHQ-9: Item 9 answered', 'severity': 'alert', 'at': '2026-09-01T18:00:00Z',
        'review': {'by': 'Dr Démo', 'at': '2026-09-02T09:00:00Z', 'note': 'Discussed in session; safe.'}},
      {'key': 'lowmood:1', 'label': 'Low mood in the last 3 check-ins', 'severity': 'warn', 'at': '2026-09-28T18:00:00Z', 'review': null},
      {'label': 'No check-in for 3 days', 'severity': 'info'},
    ];
    p['notes'] = [
      {'at': '2026-09-10T10:00:00Z', 'by': 'Dr Démo', 'text': 'Started night shifts this month.'},
    ];
    p['methods'] = {'radr': 'radr-1', 'checkins': 'Check-ins: mood, anxiety, sleep and energy, each 1 to 5.', 'questionnaireFlags': 'As defined.', 'steadyBuild': 'abc1234'};
    p['before'] = {
      'assessments': [
        {'at': '2026-08-20T10:00:00Z', 'key': 'phq9', 'name': 'PHQ-9', 'total': 6, 'max': 27, 'band': 'Mild'},
      ],
    };
    final r = p['radr'] as Map<String, dynamic>;
    r['method'] = {'baselineDays': 28, 'baselineGap': 7, 'baselineMin': 14, 'smoothDays': 3, 'notable': 1.5, 'cap': 4};
    r['exclusions'] = [
      {'domain': 'sleep', 'since': 0, 'by': 'Dr Démo', 'reason': 'night shifts'},
    ];
    r['start'] = {'day': '2026-09-15', 'features': {'sleep_min': {'value': 410, 'z': 0.2, 'usual': 420}, 'rhr': {'value': 61, 'z': 0.1, 'usual': 60}}};
    p['lastHeidiExport'] = {'at': 1788000000000, 'from': '2026-08-01', 'to': '2026-08-31', 'part': 2, 'by': 'Dr Démo', 'radr': 'radr-0'};
    return raw;
  }

  test('1.0 exports: flag reviews, clinician notes, methods and the Heidi series', () {
    final p = ExportBundle.fromJson(clinical(sample())).patients.single;
    expect(p.flags.where((f) => f.reviewable), hasLength(2));
    final reviewed = p.flags.first;
    expect(reviewed.reviewText((d) => '${d.day}/${d.month}'), 'reviewed by Dr Démo on 2/9 ("Discussed in session; safe.")');
    expect(p.flags[1].reviewText((d) => ''), 'not yet marked as reviewed in Steady');
    expect(p.flags[2].reviewText((d) => ''), '', reason: 'not a flag that can be reviewed');
    expect(p.notes.single.text, 'Started night shifts this month.');
    expect(p.methods['radr'], 'radr-1');
    expect(p.before.single.total, 6);
    expect(p.radr!.method['notable'], 1.5);
    expect(p.radr!.exclusions.single['reason'], 'night shifts');
    expect(p.lastHeidi!.part, 2);
    expect(p.lastHeidi!.to, '2026-08-31');

    final x = Excel.decodeBytes(buildWorkbook(ExportBundle.fromJson(clinical(sample()))));
    expect(x.tables['Flags']!.maxRows, 3);
    expect(x.tables['Clinician notes']!.maxRows, 2);
    final about = x.tables['About']!.rows.map((r) => r.map((c) => c?.value?.toString() ?? '').join('|')).join('\n');
    expect(about, contains('RADR method|radr-1'));
    expect(about, contains('Steady build|abc1234'));
  });

  test('the Heidi PDF builds: everything, a part of a series (method changed), chosen dates, and empty', () async {
    for (final kind in HeidiKind.values) {
      final b = ExportBundle.fromJson(clinical(sample()));
      final p = b.patients.single;
      final bytes = await buildHeidiPdf(b, p, kind: kind, previous: p.lastHeidi);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-', reason: '$kind');
      final dir = Platform.environment['STEADY_PREVIEW_DIR'];
      if (dir != null && dir.isNotEmpty) File('$dir/heidi-${kind.name}.pdf').writeAsBytesSync(bytes);
    }
    final empty = ExportBundle.fromJson(sample(days: 1));
    final p = empty.patients.single;
    final bytes = await buildHeidiPdf(empty, p, kind: HeidiKind.since, previous: null);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    final demo = ExportBundle.fromJson(jsonDecode(File('test/fixtures/demo_export.json').readAsStringSync()) as Map<String, dynamic>);
    expect(String.fromCharCodes((await buildHeidiPdf(demo, demo.patients.single, kind: HeidiKind.all)).take(5)), '%PDF-');
  });

  // A report for the fictional demo patient B (generated by the server's demo data, see
  // server/pb_hooks/lib/research_demo.js). STEADY_PREVIEW_DIR keeps a copy to look at.
  test('the PDF report for a fictional demo patient, with RADR', () async {
    final raw = jsonDecode(File('test/fixtures/demo_export.json').readAsStringSync()) as Map<String, dynamic>;
    final b = ExportBundle.fromJson(raw);
    expect(b.patients.single.radr!.rated, isNotEmpty);
    final bytes = await buildPdfReport(b, b.patients.single);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    final dir = Platform.environment['STEADY_PREVIEW_DIR'];
    if (dir != null && dir.isNotEmpty) {
      File('$dir/report-demo-b.pdf').writeAsBytesSync(bytes);
      File('$dir/export-demo-b.xlsx').writeAsBytesSync(buildWorkbook(b));
    }
  });
}
