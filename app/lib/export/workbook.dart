// SPDX-License-Identifier: AGPL-3.0-or-later
// One or more patients' Steady records as an Excel workbook: a sheet per kind of data, one row
// per entry, ready for filtering and pivot tables.
import 'dart:typed_data';

import 'package:excel/excel.dart';

import 'export_data.dart';

Uint8List buildWorkbook(ExportBundle bundle) {
  final x = Excel.createExcel();
  final first = x.getDefaultSheet() ?? 'Sheet1';

  Sheet sheet(String name, List<String> headers) {
    final s = x[name];
    s.appendRow([for (final h in headers) TextCellValue(h)]);
    for (var i = 0; i < headers.length; i++) {
      s.cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0)).cellStyle = CellStyle(bold: true);
    }
    return s;
  }

  CellValue? t(String v) => v.isEmpty ? null : TextCellValue(v);
  CellValue? n(num? v) => v == null ? null : (v is int || v == v.roundToDouble() ? IntCellValue(v.round()) : DoubleCellValue(v.toDouble()));
  CellValue dt(DateTime d) => DateTimeCellValue(year: d.year, month: d.month, day: d.day, hour: d.hour, minute: d.minute);

  final about = sheet('About', ['Item', 'Value']);
  for (final row in [
    ['Practice', bundle.practice],
    ['Prepared by', bundle.clinician],
    ['Prepared on', timeText(bundle.generatedAt)],
    ['Patients', '${bundle.patients.length}'],
    ['Note', 'Confidential health information from Steady. Keep it in the patient file. Flags are review aids, not a diagnosis.'],
    ['RADR', 'Research only: how far watch data and check-ins are from the person\'s own normal, 0 to 4. Not a risk score or diagnosis. See docs/RADR.md.'],
    // which version of each method produced the numbers
    for (final e in _methods(bundle).entries) [e.key, e.value],
  ]) {
    about.appendRow([TextCellValue(row[0]), TextCellValue(row[1])]);
  }

  final patients = sheet('Patients', ['Patient', 'Name in the app', 'Joined', 'Access', 'From', 'To', 'Check-ins', 'Questionnaires', 'Exercises', 'Watch days']);
  final checkins = sheet('Check-ins', ['Patient', 'When', 'Mood', 'Anxiety', 'Sleep', 'Energy', 'Note']);
  final scores = sheet('Questionnaires', ['Patient', 'When', 'Questionnaire', 'Score', 'Out of', 'Band', 'Severity', 'Flags']);
  final answers = sheet('Answers', ['Patient', 'When', 'Questionnaire', 'Item', 'Question', 'Answer', 'Answer text']);
  final exercises = sheet('Exercises', ['Patient', 'When', 'Exercise', 'Minutes', 'Started by the patient']);
  final flags = sheet('Flags', ['Patient', 'When', 'Flag', 'Severity', 'Reviewed in Steady', 'Reviewed by', 'Reviewed on', 'Review note']);
  final notes = sheet('Clinician notes', ['Patient', 'When', 'By', 'Note']);
  final keys = <String>{for (final p in bundle.patients) for (final d in p.wearableDays) ...d.values.keys};
  final order = [...kWearableLabels.keys.where(keys.contains), ...keys.where((k) => !kWearableLabels.containsKey(k)).toList()..sort()];
  final watch = sheet('Watch', ['Patient', 'Day', for (final k in order) kWearableLabels[k] == null ? k : '${kWearableLabels[k]!.$1}${kWearableLabels[k]!.$2.isEmpty ? '' : ' (${kWearableLabels[k]!.$2})'}']);

  final radr = sheet('RADR (research)', [
    'Patient', 'Day', 'Watch index (0-4)', 'Check-in score (0-4)', 'Combined', 'Domains away from usual',
    'Sleep', 'Body clock', 'Activity', 'Heart',
  ]);

  for (final p in bundle.patients) {
    final who = TextCellValue(p.name);
    patients.appendRow([
      who,
      t(p.selfName),
      p.joinedAt == null ? null : dt(p.joinedAt!),
      TextCellValue(p.active ? 'active' : 'stopped'),
      p.from == null ? null : dt(p.from!),
      p.to == null ? null : dt(p.to!),
      IntCellValue(p.checkins.length),
      IntCellValue(p.assessments.length),
      IntCellValue(p.exercises.length),
      IntCellValue(p.wearableDays.length),
    ]);
    for (final c in p.checkins) {
      checkins.appendRow([who, dt(c.at), IntCellValue(c.mood), IntCellValue(c.anxiety), IntCellValue(c.sleep), IntCellValue(c.energy), t(c.note)]);
    }
    for (final a in p.assessments) {
      scores.appendRow([who, dt(a.at), TextCellValue(a.name), n(a.total), n(a.max), t(a.band), TextCellValue(a.severity), t(a.flags.map((f) => f.label).join('; '))]);
      final inst = p.instruments[a.key];
      final items = inst?.items ?? [for (final k in a.answers.keys) (id: k, text: '')];
      for (final it in items) {
        if (!a.answers.containsKey(it.id)) continue;
        final v = a.answers[it.id];
        answers.appendRow([
          who,
          dt(a.at),
          TextCellValue(a.name),
          TextCellValue(it.id),
          t(it.text),
          v is num ? n(v) : t('${v ?? ''}'),
          t(p.answerLabel(a.key, it.id, v)),
        ]);
      }
    }
    for (final e in p.exercises) {
      exercises.appendRow([who, dt(e.at), TextCellValue(e.name), n(e.minutes), TextCellValue(e.selfStarted ? 'yes' : 'no')]);
    }
    for (final f in p.flags.where((f) => f.reviewable)) {
      final r = f.review;
      flags.appendRow([
        who,
        f.at == null ? null : dt(f.at!),
        TextCellValue(f.label),
        TextCellValue(f.severity),
        TextCellValue(r == null ? 'not yet' : 'yes'),
        t(r?.by ?? ''),
        r?.at == null ? null : dt(r!.at!),
        t(r?.note ?? ''),
      ]);
    }
    for (final nt in p.notes) {
      notes.appendRow([who, dt(nt.at), t(nt.by), TextCellValue(nt.text)]);
    }
    for (final d in p.radr?.rated ?? const <ExportRadrDay>[]) {
      radr.appendRow([
        who,
        TextCellValue(dayText(d.day)),
        n(d.watch),
        n(d.self),
        n(d.combined),
        IntCellValue(d.convergent),
        for (final k in ExportRadr.domainKeys) n(d.domains[k]),
      ]);
    }
    for (final d in p.wearableDays) {
      watch.appendRow([who, TextCellValue(d.day), for (final k in order) d.values[k] is num ? n(d.values[k] as num) : null]);
    }
  }

  if (first != 'About') x.delete(first);
  x.setDefaultSheet('About');
  return Uint8List.fromList(x.encode() ?? const []);
}

/// Method versions across the export (normally one of each), for the About sheet.
Map<String, String> _methods(ExportBundle bundle) {
  final radr = <String>{}, build = <String>{};
  var checkins = '', flags = '';
  for (final p in bundle.patients) {
    final v = p.radr?.version.isNotEmpty == true ? p.radr!.version : (p.methods['radr'] ?? '');
    if (v.isNotEmpty) radr.add(v);
    if ((p.methods['steadyBuild'] ?? '').isNotEmpty) build.add(p.methods['steadyBuild']!);
    if (checkins.isEmpty) checkins = p.methods['checkins'] ?? '';
    if (flags.isEmpty) flags = p.methods['questionnaireFlags'] ?? '';
  }
  return {
    if (radr.isNotEmpty) 'RADR method': radr.join(', '),
    if (checkins.isNotEmpty) 'Check-ins': checkins,
    if (flags.isNotEmpty) 'Questionnaire flags': flags,
    if (build.isNotEmpty) 'Steady build': build.join(', '),
  };
}
