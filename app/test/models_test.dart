// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:steady/models.dart';
import 'package:steady/services/api.dart';

void main() {
  RecordModel instrument(Map<String, dynamic> definition, {String kind = 'questionnaire'}) => RecordModel.fromJson({
        'id': 'i1',
        'key': definition['key'],
        'name': definition['name'],
        'kind': kind,
        'licenceStatus': 'cleared',
        'active': true,
        'builtin': true,
        'definition': definition,
      });

  test('parses items from response sets and inline options', () {
    final i = Instrument.fromRecord(instrument({
      'key': 'x',
      'name': 'X',
      'responseSets': {
        'yn': [
          {'label': 'No', 'value': 0},
          {'label': 'Yes', 'value': 1},
        ],
      },
      'items': [
        {'id': 'a', 'text': 'A?', 'responseSet': 'yn'},
        {
          'id': 'b',
          'text': 'B?',
          'type': 'text',
          'required': false,
          'showIf': {
            'anyOf': [
              {'item': 'a', 'op': '=', 'value': 1},
            ],
          },
        },
      ],
    }));
    expect(i.items.length, 2);
    expect(i.items.first.options.map((o) => o.label), ['No', 'Yes']);
    expect(i.items[1].required, false);
    expect(i.items[1].visible({'a': 0}), false);
    expect(i.items[1].visible({'a': 1}), true);
    expect(i.sendable, true);
  });

  test('parses a breathing exercise', () {
    final i = Instrument.fromRecord(instrument({
      'key': 'b',
      'name': 'Box',
      'exercise': {
        'type': 'breathing',
        'rounds': 6,
        'phases': [
          {'label': 'In', 'seconds': 4, 'expand': true},
        ],
      },
    }, kind: 'exercise'));
    expect(i.isQuestionnaire, false);
    expect(i.exercise!.rounds, 6);
    expect(i.exercise!.phases.single.expand, true);
  });

  test('assignment reads its expanded instrument and score', () {
    final a = Assignment.fromRecord(RecordModel.fromJson({
      'id': 'a1',
      'patient': 'p',
      'clinician': 'c',
      'instrument': 'i1',
      'status': 'done',
      'created': '2026-10-14 08:00:00.000Z',
      'completedAt': '2026-10-14 09:00:00.000Z',
      'score': {
        'total': 17,
        'max': 27,
        'band': 'Moderately severe',
        'severity': 'alert',
        'flags': [
          {'label': 'Item 9 endorsed: review', 'severity': 'alert'},
        ],
      },
      'expand': {
        'instrument': {'id': 'i1', 'name': 'PHQ-9', 'kind': 'questionnaire', 'definition': {}},
      },
    }));
    expect(a.name, 'PHQ-9');
    expect(a.score!.total, 17);
    expect(a.score!.flags.single.severity, Severity.alert);
    expect(a.completedAt, isNotNull);
  });

  test('patient summary', () {
    final p = PatientSummary.fromJson({
      'id': 'p',
      'name': 'Lerato Mokoena',
      'mood': [null, 3, 2],
      'anxiety': [null, 3, 4],
      'flags': [
        {'label': 'Low mood in the last 3 check-ins', 'severity': 'warn'},
      ],
      'lastCheckin': {'ts': 1760000000000, 'mood': 2},
    });
    expect(p.initials, 'LM');
    expect(p.mood, [null, 3.0, 2.0]);
    expect(p.flags.single.severity, Severity.warn);
    expect(p.lastMood, 2);
  });

  test('patient summary: RADR flags with their reviews, and why they are where they are in the list', () {
    final p = PatientSummary.fromJson({
      'id': 'p',
      'name': 'Demo C',
      'radr': {
        'day': '2026-11-02',
        'convergent': 2,
        'level': 'away',
        'flags': [
          {'key': 'radr:sleep:2026-10-28', 'domain': 'sleep', 'since': '2026-10-28', 'day': '2026-11-02', 'score': 4,
            'reviewed': {'by': 'Dr Demo', 'at': 1793600000000}},
          {'key': 'radr:cardiac:2026-10-30', 'domain': 'cardiac', 'since': '2026-10-30', 'day': '2026-11-02', 'score': 1.8, 'reviewed': null},
        ],
      },
      'attention': {
        'rank': 2,
        'why': {'kind': 'radr', 'text': 'RADR: 2 of 4 areas of their watch data were away from their usual on Mon 2 Nov.'},
      },
    });
    expect(p.radr!.level, 'away');
    expect(p.radr!.flags.map((f) => f.domain), ['sleep', 'cardiac']);
    expect(p.radr!.flags.first.reviewed!.by, 'Dr Demo');
    expect(p.radr!.flags.first.score, 4.0);
    expect(p.radr!.flags.last.reviewed, isNull);
    expect(p.whyHere, startsWith('RADR: 2 of 4 areas'));
    // a summary from before flags existed still reads
    expect(PatientSummary.fromJson({'id': 'q', 'name': 'Q', 'radr': {'day': '2026-11-02', 'convergent': 1, 'level': 'away'}}).radr!.flags, isEmpty);
  });

  test('server addresses are normalised', () {
    expect(normaliseServerUrl('steady.example.co.za'), 'https://steady.example.co.za');
    expect(normaliseServerUrl(' https://steady.example.co.za/ '), 'https://steady.example.co.za');
    expect(normaliseServerUrl('http://192.168.1.5:8090'), 'http://192.168.1.5:8090');
    expect(normaliseServerUrl(''), isNull);
    expect(normaliseServerUrl('ftp://x'), isNull);
  });
}
