// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:pocketbase/pocketbase.dart';

DateTime? parsePbDate(Object? v) {
  if (v is! String || v.isEmpty) return null;
  return DateTime.tryParse(v.replaceFirst(' ', 'T'))?.toLocal();
}

DateTime? fromMs(Object? v) =>
    (v is num && v > 0) ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;

Map<String, dynamic> asMap(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

List<dynamic> asList(Object? v) => v is List ? v : const [];

enum Severity { none, info, warn, alert }

Severity severityOf(Object? s) => switch (s) {
      'alert' => Severity.alert,
      'warn' => Severity.warn,
      'info' => Severity.info,
      _ => Severity.none,
    };

class CrisisLine {
  final String label, number, hours;
  CrisisLine(this.label, this.number, this.hours);
  factory CrisisLine.fromJson(Map<String, dynamic> j) =>
      CrisisLine('${j['label'] ?? ''}', '${j['number'] ?? ''}', '${j['hours'] ?? ''}');
}

class AppConfig {
  final String practiceName, crisisNotice, consentVersion, consentText, vapidPublicKey;

  /// "staff": psychologists and administrators must use two-step sign-in. "off": optional.
  final String twoStep;

  /// The newest Android build on the server ('' if none) and where to download it.
  final String appBuild, apkPath;

  /// Whether that build installs over older copies (signed with the permanent key).
  final bool appUpdatable;
  final List<CrisisLine> crisisLines;

  /// The practice's look, installed on its server by OpenWorks IT: a tagline, an accent
  /// colour like '#B0690C' and the logo's address on the server ('' when not set: plain Steady).
  final String brandTagline, brandAccent, brandLogo;
  AppConfig({
    required this.practiceName,
    required this.crisisNotice,
    required this.consentVersion,
    required this.consentText,
    required this.vapidPublicKey,
    required this.crisisLines,
    this.twoStep = 'staff',
    this.appBuild = '',
    this.apkPath = '',
    this.appUpdatable = false,
    this.brandTagline = '',
    this.brandAccent = '',
    this.brandLogo = '',
  });

  /// Used until the server answers, and if it can't be reached.
  static AppConfig fallback() => AppConfig(
        practiceName: 'Your practice',
        crisisNotice: "This app isn't monitored around the clock. If you need help now, call one of these numbers.",
        consentVersion: '',
        consentText: '',
        vapidPublicKey: '',
        crisisLines: [
          CrisisLine('SADAG Suicide Crisis Line', '0800 567 567', '24 hours, free'),
          CrisisLine('Emergency services from a mobile', '112', '24 hours'),
        ],
      );

  factory AppConfig.fromJson(Map<String, dynamic> j) => AppConfig(
        practiceName: '${j['practiceName'] ?? 'Your practice'}',
        crisisNotice: '${j['crisisNotice'] ?? ''}',
        consentVersion: '${j['consentVersion'] ?? ''}',
        consentText: '${j['consentText'] ?? ''}',
        vapidPublicKey: '${j['vapidPublicKey'] ?? ''}',
        twoStep: '${j['twoStep'] ?? 'staff'}',
        crisisLines: asList(j['crisisLines']).map((e) => CrisisLine.fromJson(asMap(e))).toList(),
        appBuild: '${asMap(j['app'])['build'] ?? ''}',
        apkPath: '${asMap(j['app'])['apk'] ?? ''}',
        appUpdatable: asMap(j['app'])['updatable'] == true,
        brandTagline: '${asMap(j['brand'])['tagline'] ?? ''}',
        brandAccent: '${asMap(j['brand'])['accent'] ?? ''}',
        brandLogo: '${asMap(j['brand'])['logo'] ?? ''}',
      );
}

/* ------------------------------------------------------------------ instruments */

class ChoiceOption {
  final String label;
  final num value;
  ChoiceOption(this.label, this.value);
  factory ChoiceOption.fromJson(Map<String, dynamic> j) =>
      ChoiceOption('${j['label']}', (j['value'] as num?) ?? 0);
  Map<String, dynamic> toJson() => {'label': label, 'value': value};
}

class Condition {
  final String item, op;
  final num value;
  Condition(this.item, this.op, this.value);
  bool holds(Map<String, Object?> answers) {
    final v = answers[item];
    if (v is! num) return false;
    return switch (op) {
      '>' => v > value,
      '>=' => v >= value,
      '=' => v == value,
      '<' => v < value,
      '<=' => v <= value,
      _ => false,
    };
  }
}

class Item {
  final String id, text, type, preamble;
  final List<ChoiceOption> options;
  final bool required;
  final num min, max;
  final int maxLength;
  final List<Condition> showIf;
  Item({
    required this.id,
    required this.text,
    required this.type,
    required this.options,
    required this.required,
    this.preamble = '',
    this.min = 0,
    this.max = 100,
    this.maxLength = 1000,
    this.showIf = const [],
  });

  /// Mirrors the server's rule: visible when any condition holds (or there are none).
  bool visible(Map<String, Object?> answers) => showIf.isEmpty || showIf.any((c) => c.holds(answers));
}

class Phase {
  final String label;
  final int seconds;
  final bool expand;
  Phase(this.label, this.seconds, this.expand);
}

class StepDef {
  final String title, prompt;
  StepDef(this.title, this.prompt);
}

class ExerciseDef {
  final String type; // breathing | steps
  final int rounds;
  final List<Phase> phases;
  final List<StepDef> steps;
  ExerciseDef(this.type, this.rounds, this.phases, this.steps);
}

class Instrument {
  final String id, key, name, kind, licenceStatus, createdBy;
  final bool builtin, active;
  final Map<String, dynamic> definition;
  Instrument({
    required this.id,
    required this.key,
    required this.name,
    required this.kind,
    required this.licenceStatus,
    required this.createdBy,
    required this.builtin,
    required this.active,
    required this.definition,
  });

  factory Instrument.fromRecord(RecordModel r) => Instrument(
        id: r.id,
        key: r.getStringValue('key'),
        name: r.getStringValue('name'),
        kind: r.getStringValue('kind'),
        licenceStatus: r.getStringValue('licenceStatus'),
        createdBy: r.getStringValue('createdBy'),
        builtin: r.getBoolValue('builtin'),
        active: r.getBoolValue('active'),
        definition: asMap(r.data['definition']),
      );

  bool get isQuestionnaire => kind == 'questionnaire';
  bool get sendable => active && (licenceStatus == 'cleared' || licenceStatus == 'custom');
  String get fullName => '${definition['fullName'] ?? ''}';
  String get summary => '${definition['summary'] ?? ''}';
  String get instructions => '${definition['instructions'] ?? ''}';
  String get licenceName => '${asMap(definition['licence'])['name'] ?? ''}';
  String get licenceUrl => '${asMap(definition['licence'])['url'] ?? ''}';
  String get sourceName => '${asMap(definition['source'])['name'] ?? ''}';

  List<Item> get items {
    final sets = asMap(definition['responseSets']);
    return asList(definition['items']).map((raw) {
      final j = asMap(raw);
      final opts = j['options'] != null ? asList(j['options']) : asList(sets['${j['responseSet']}']);
      return Item(
        id: '${j['id']}',
        text: '${j['text'] ?? ''}',
        type: '${j['type'] ?? 'choice'}',
        options: opts.map((o) => ChoiceOption.fromJson(asMap(o))).toList(),
        required: j['required'] != false,
        preamble: '${j['preamble'] ?? ''}',
        min: (j['min'] as num?) ?? 0,
        max: (j['max'] as num?) ?? 100,
        maxLength: (j['maxLength'] as num?)?.toInt() ?? 1000,
        showIf: asList(asMap(j['showIf'])['anyOf'])
            .map((c) => asMap(c))
            .map((c) => Condition('${c['item']}', '${c['op']}', (c['value'] as num?) ?? 0))
            .toList(),
      );
    }).toList();
  }

  ExerciseDef? get exercise {
    final e = asMap(definition['exercise']);
    if (e.isEmpty) return null;
    return ExerciseDef(
      '${e['type']}',
      (e['rounds'] as num?)?.toInt() ?? 1,
      asList(e['phases']).map((p) {
        final m = asMap(p);
        return Phase('${m['label']}', (m['seconds'] as num?)?.toInt() ?? 4, m['expand'] == true);
      }).toList(),
      asList(e['steps']).map((s) {
        final m = asMap(s);
        return StepDef('${m['title']}', '${m['prompt'] ?? ''}');
      }).toList(),
    );
  }
}

/* ------------------------------------------------------------------ results */

class Flag {
  final String label;
  final Severity severity;
  Flag(this.label, this.severity);
  factory Flag.fromJson(Map<String, dynamic> j) => Flag('${j['label']}', severityOf(j['severity']));
}

class Subscale {
  final String id, label;
  final num total;
  final num? max;
  Subscale(this.id, this.label, this.total, this.max);
}

class Score {
  final num total, max;
  final String band, note;
  final Severity severity;
  final List<Flag> flags;
  final List<Subscale> subscales;
  Score(this.total, this.max, this.band, this.severity, this.flags, this.subscales, this.note);
  static Score? fromJson(Object? raw) {
    final j = asMap(raw);
    if (j.isEmpty) return null;
    return Score(
      (j['total'] as num?) ?? 0,
      (j['max'] as num?) ?? 0,
      '${j['band'] ?? ''}',
      severityOf(j['severity']),
      asList(j['flags']).map((f) => Flag.fromJson(asMap(f))).toList(),
      asList(j['subscales']).map((s) {
        final m = asMap(s);
        return Subscale('${m['id']}', '${m['label']}', (m['total'] as num?) ?? 0, m['max'] as num?);
      }).toList(),
      '${j['note'] ?? ''}',
    );
  }
}

class Assignment {
  final String id, patientId, clinicianId, instrumentId, status, note, repeat;
  final bool selfStarted;
  final DateTime? created, availableFrom, completedAt;
  final Map<String, dynamic> result;
  final Score? score;
  final Instrument? instrument;
  Assignment({
    required this.id,
    required this.patientId,
    required this.clinicianId,
    required this.instrumentId,
    required this.status,
    required this.note,
    required this.repeat,
    required this.selfStarted,
    required this.created,
    required this.availableFrom,
    required this.completedAt,
    required this.result,
    required this.score,
    required this.instrument,
  });

  factory Assignment.fromRecord(RecordModel r) {
    final rawInst = asMap(r.data['expand'])['instrument'];
    final inst = rawInst is Map ? RecordModel.fromJson(Map<String, dynamic>.from(rawInst)) : null;
    return Assignment(
      id: r.id,
      patientId: r.getStringValue('patient'),
      clinicianId: r.getStringValue('clinician'),
      instrumentId: r.getStringValue('instrument'),
      status: r.getStringValue('status'),
      note: r.getStringValue('note'),
      repeat: r.getStringValue('repeat'),
      selfStarted: r.getBoolValue('selfStarted'),
      created: parsePbDate(r.data['created']),
      availableFrom: parsePbDate(r.data['availableFrom']),
      completedAt: parsePbDate(r.data['completedAt']),
      result: asMap(r.data['result']),
      score: Score.fromJson(r.data['score']),
      instrument: inst == null ? null : Instrument.fromRecord(inst),
    );
  }

  bool get available => availableFrom == null || !availableFrom!.isAfter(DateTime.now());
  String get name => instrument?.name ?? 'Activity';
}

class Checkin {
  final String id, note;
  final int mood, anxiety, sleep, energy;
  final DateTime created;
  Checkin(this.id, this.created, this.mood, this.anxiety, this.sleep, this.energy, this.note);
  factory Checkin.fromRecord(RecordModel r) => Checkin(
        r.id,
        parsePbDate(r.data['created']) ?? DateTime.now(),
        r.getIntValue('mood'),
        r.getIntValue('anxiety'),
        r.getIntValue('sleep'),
        r.getIntValue('energy'),
        r.getStringValue('note'),
      );
}

class WearableSummary {
  final bool connected;
  final int days14;
  final String lastDay;
  const WearableSummary(this.connected, this.days14, this.lastDay);
  factory WearableSummary.fromJson(Map<String, dynamic> j) =>
      WearableSummary(j['connected'] == true, (j['days14'] as num?)?.toInt() ?? 0, '${j['lastDay'] ?? ''}');
}

class BiometricDay {
  final String day;
  final Map<String, dynamic> values;
  const BiometricDay(this.day, this.values);
  double? number(String k) => values[k] is num ? (values[k] as num).toDouble() : null;
  String text(String k) => values[k] is String ? values[k] as String : '';
}

class BaselinePoint {
  final String day;
  final double? lo, mid, hi;
  final int n;
  const BaselinePoint(this.day, this.lo, this.mid, this.hi, this.n);
}

class Biometrics {
  final String from, to;
  final bool connected;
  final List<BiometricDay> days;
  final Map<String, List<BaselinePoint>> baseline;
  final int baselineMin;
  const Biometrics(this.from, this.to, this.connected, this.days, this.baseline, this.baselineMin);

  factory Biometrics.fromJson(Map<String, dynamic> j) {
    double? d(Object? v) => v is num ? v.toDouble() : null;
    final base = <String, List<BaselinePoint>>{};
    asMap(j['baseline']).forEach((k, v) {
      base[k] = asList(v).map((p) {
        final m = asMap(p);
        return BaselinePoint('${m['day']}', d(m['lo']), d(m['mid']), d(m['hi']), (m['n'] as num?)?.toInt() ?? 0);
      }).toList();
    });
    return Biometrics(
      '${j['from'] ?? ''}',
      '${j['to'] ?? ''}',
      j['connected'] == true,
      asList(j['days']).map((x) {
        final m = asMap(x);
        return BiometricDay('${m['day']}', asMap(m['values']));
      }).toList(),
      base,
      (j['baselineMin'] as num?)?.toInt() ?? 7,
    );
  }

  BiometricDay? dayOf(String day) {
    for (final d in days) {
      if (d.day == day) return d;
    }
    return null;
  }

  BaselinePoint? baselineOf(String metric, String day) {
    for (final b in baseline[metric] ?? const <BaselinePoint>[]) {
      if (b.day == day) return b;
    }
    return null;
  }
}

class PatientSummary {
  /// [name] is what the psychologist calls the patient; [selfName] is the patient's own.
  final String id, name, selfName;
  final bool active;
  final DateTime? lastCheckinAt;
  final int? lastMood;
  final List<double?> mood, anxiety;
  final List<Flag> flags;
  final int pending;
  final WearableSummary wearable;

  /// A colleague's patient, shared with this psychologist to read; [owner] is that colleague.
  final bool shared;
  final String owner;
  PatientSummary({
    required this.id,
    required this.name,
    this.selfName = '',
    required this.active,
    required this.lastCheckinAt,
    required this.lastMood,
    required this.mood,
    required this.anxiety,
    required this.flags,
    required this.pending,
    required this.wearable,
    this.shared = false,
    this.owner = '',
  });

  factory PatientSummary.fromJson(Map<String, dynamic> j) {
    final last = asMap(j['lastCheckin']);
    List<double?> series(Object? v) => asList(v).map((x) => x is num ? x.toDouble() : null).toList();
    return PatientSummary(
      id: '${j['id']}',
      name: '${j['name'] ?? ''}',
      selfName: '${j['selfName'] ?? ''}',
      active: j['active'] == true,
      lastCheckinAt: fromMs(last['ts']),
      lastMood: (last['mood'] as num?)?.toInt(),
      mood: series(j['mood']),
      anxiety: series(j['anxiety']),
      flags: asList(j['flags']).map((f) => Flag.fromJson(asMap(f))).toList(),
      pending: (j['pending'] as num?)?.toInt() ?? 0,
      wearable: WearableSummary.fromJson(asMap(j['wearable'])),
      shared: j['shared'] == true,
      owner: '${j['owner'] ?? ''}',
    );
  }

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    return parts.take(2).map((p) => p[0].toUpperCase()).join();
  }
}

class AppNotification {
  final String id, kind, title, body, patientId, assignmentId;
  final Severity severity;
  final bool read;
  final DateTime created;
  AppNotification(this.id, this.kind, this.title, this.body, this.patientId, this.assignmentId, this.severity, this.read,
      this.created);
  factory AppNotification.fromRecord(RecordModel r) => AppNotification(
        r.id,
        r.getStringValue('kind'),
        r.getStringValue('title'),
        r.getStringValue('body'),
        r.getStringValue('patient'),
        r.getStringValue('assignment'),
        severityOf(r.getStringValue('severity')),
        r.getBoolValue('read'),
        parsePbDate(r.data['created']) ?? DateTime.now(),
      );
}
