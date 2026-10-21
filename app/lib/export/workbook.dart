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
  ]) {
    about.appendRow([TextCellValue(row[0]), TextCellValue(row[1])]);
  }

  final patients = sheet('Patients', ['Patient', 'Name in the app', 'Joined', 'Access', 'From', 'To', 'Check-ins', 'Questionnaires', 'Exercises', 'Watch days']);
  final checkins = sheet('Check-ins', ['Patient', 'When', 'Mood', 'Anxiety', 'Sleep', 'Energy', 'Note']);
  final scores = sheet('Questionnaires', ['Patient', 'When', 'Questionnaire', 'Score', 'Out of', 'Band', 'Severity', 'Flags']);
  final answers = sheet('Answers', ['Patient', 'When', 'Questionnaire', 'Item', 'Question', 'Answer', 'Answer text']);
  final exercises = sheet('Exercises', ['Patient', 'When', 'Exercise', 'Minutes', 'Started by the patient']);
  final keys = <String>{for (final p in bundle.patients) for (final d in p.wearableDays) ...d.values.keys};
  final order = [...kWearableLabels.keys.where(keys.contains), ...keys.where((k) => !kWearableLabels.containsKey(k)).toList()..sort()];
  final watch = sheet('Watch', ['Patient', 'Day', for (final k in order) kWearableLabels[k] == null ? k : '${kWearableLabels[k]!.$1}${kWearableLabels[k]!.$2.isEmpty ? '' : ' (${kWearableLabels[k]!.$2})'}']);

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
    for (final d in p.wearableDays) {
      watch.appendRow([who, TextCellValue(d.day), for (final k in order) d.values[k] is num ? n(d.values[k] as num) : null]);
    }
  }

  if (first != 'About') x.delete(first);
  x.setDefaultSheet('About');
  return Uint8List.fromList(x.encode() ?? const []);
}
