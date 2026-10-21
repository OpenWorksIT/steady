// SPDX-License-Identifier: AGPL-3.0-or-later
// The export from /api/steady/patients/{id}/export and /api/steady/export, as Dart objects.
import '../models.dart' show asList, asMap;

DateTime? _date(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();
double? _num(Object? v) => v is num ? v.toDouble() : null;

class ExportCheckin {
  final DateTime at;
  final int mood, anxiety, sleep, energy;
  final String note;
  ExportCheckin(this.at, this.mood, this.anxiety, this.sleep, this.energy, this.note);
  int scale(String k) => switch (k) { 'mood' => mood, 'anxiety' => anxiety, 'sleep' => sleep, _ => energy };
}

class ExportFlag {
  final String label, severity;
  ExportFlag(this.label, this.severity);
  static ExportFlag fromJson(Object? raw) {
    final j = asMap(raw);
    return ExportFlag('${j['label'] ?? ''}', '${j['severity'] ?? 'none'}');
  }
}

class ExportAssessment {
  final DateTime at;
  final String key, name, band, severity;
  final double? total, max;
  final List<ExportFlag> flags;
  final Map<String, dynamic> answers;
  ExportAssessment(this.at, this.key, this.name, this.total, this.max, this.band, this.severity, this.flags, this.answers);
}

class ExportExercise {
  final DateTime at;
  final String name;
  final bool selfStarted;
  final int? minutes;
  ExportExercise(this.at, this.name, this.selfStarted, this.minutes);
}

class ExportInstrument {
  final String name;
  final List<({String id, String text})> items;
  final Map<String, dynamic> responseSets;
  ExportInstrument(this.name, this.items, this.responseSets);
}

class ExportPatient {
  final String id, name, selfName;
  final DateTime? joinedAt, from, to;
  final bool active, wearableConnected;
  final List<ExportCheckin> checkins;
  final List<ExportAssessment> assessments;
  final List<ExportExercise> exercises;
  final List<ExportFlag> flags;
  final List<({String day, Map<String, dynamic> values})> wearableDays;
  final Map<String, ExportInstrument> instruments;
  ExportPatient({
    required this.id,
    required this.name,
    required this.selfName,
    required this.joinedAt,
    required this.from,
    required this.to,
    required this.active,
    required this.wearableConnected,
    required this.checkins,
    required this.assessments,
    required this.exercises,
    required this.flags,
    required this.wearableDays,
    required this.instruments,
  });

  factory ExportPatient.fromJson(Map<String, dynamic> j) {
    final p = asMap(j['patient']);
    final w = asMap(j['wearable']);
    final inst = <String, ExportInstrument>{};
    asMap(j['instruments']).forEach((k, v) {
      final m = asMap(v);
      inst[k] = ExportInstrument(
        '${m['name'] ?? k}',
        asList(m['items']).map((it) => (id: '${asMap(it)['id']}', text: '${asMap(it)['text'] ?? ''}')).toList(),
        asMap(m['responseSets']),
      );
    });
    return ExportPatient(
      id: '${p['id']}',
      name: '${p['name'] ?? ''}',
      selfName: '${p['selfName'] ?? ''}',
      joinedAt: _date(p['joinedAt']),
      from: _date(j['from']),
      to: _date(j['to']),
      active: p['active'] == true,
      wearableConnected: w['connected'] == true,
      checkins: asList(j['checkins']).map((raw) {
        final c = asMap(raw);
        int n(String k) => (c[k] as num?)?.toInt() ?? 0;
        return ExportCheckin(_date(c['at']) ?? DateTime(1970), n('mood'), n('anxiety'), n('sleep'), n('energy'), '${c['note'] ?? ''}');
      }).toList(),
      assessments: asList(j['assessments']).map((raw) {
        final a = asMap(raw);
        return ExportAssessment(
          _date(a['at']) ?? DateTime(1970),
          '${a['key'] ?? ''}',
          '${a['name'] ?? ''}',
          _num(a['total']),
          _num(a['max']),
          '${a['band'] ?? ''}',
          '${a['severity'] ?? 'none'}',
          asList(a['flags']).map(ExportFlag.fromJson).toList(),
          asMap(a['answers']),
        );
      }).toList(),
      exercises: asList(j['exercises']).map((raw) {
        final e = asMap(raw);
        return ExportExercise(_date(e['at']) ?? DateTime(1970), '${e['name'] ?? ''}', e['selfStarted'] == true, (e['minutes'] as num?)?.toInt());
      }).toList(),
      flags: asList(j['flags']).map(ExportFlag.fromJson).toList(),
      wearableDays: asList(w['days']).map((raw) => (day: '${asMap(raw)['day']}', values: asMap(asMap(raw)['values']))).toList(),
      instruments: inst,
    );
  }

  /// The label for an answer value, from the instrument's response set, if there is one.
  String answerLabel(String instrumentKey, String itemId, Object? value) {
    final inst = instruments[instrumentKey];
    if (inst == null || value == null) return '';
    for (final set in inst.responseSets.values) {
      for (final opt in asList(set)) {
        final o = asMap(opt);
        if ('${o['value']}' == '$value') return '${o['label'] ?? ''}';
      }
    }
    return '';
  }
}

class ExportBundle {
  final String practice, clinician;
  final DateTime generatedAt;
  final List<ExportPatient> patients;
  ExportBundle(this.practice, this.clinician, this.generatedAt, this.patients);
  factory ExportBundle.fromJson(Map<String, dynamic> j) => ExportBundle(
        '${j['practice'] ?? ''}',
        '${j['clinician'] ?? ''}',
        _date(j['generatedAt']) ?? DateTime.now(),
        asList(j['patients']).map((p) => ExportPatient.fromJson(asMap(p))).toList(),
      );
}

String two(int n) => n.toString().padLeft(2, '0');
String dayText(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';
String timeText(DateTime d) => '${dayText(d)} ${two(d.hour)}:${two(d.minute)}';

/// A safe file name part from a patient's name.
String fileSafe(String s) {
  final t = s.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  return t.isEmpty ? 'patient' : t;
}

/// Watch values in exports, in this order (the server's lib/wearable.js has the full list).
const kWearableLabels = {
  'rhr': ('Resting heart rate', 'bpm'),
  'hr_avg': ('Average heart rate', 'bpm'),
  'hr_min': ('Lowest heart rate', 'bpm'),
  'hr_max': ('Highest heart rate', 'bpm'),
  'sleep_min': ('Sleep', 'min'),
  'sleep_deep': ('Deep sleep', 'min'),
  'sleep_light': ('Light sleep', 'min'),
  'sleep_rem': ('REM sleep', 'min'),
  'sleep_awake': ('Awake in bed', 'min'),
  'sleep_onset': ('Fell asleep', 'min from midnight'),
  'sleep_wake': ('Woke up', 'min from midnight'),
  'steps': ('Steps', 'steps'),
  'spo2_avg': ('Blood oxygen', '%'),
  'spo2_min': ('Lowest blood oxygen', '%'),
};
