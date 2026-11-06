// SPDX-License-Identifier: AGPL-3.0-or-later
//
// No signal: the patient still sees what was waiting (the copy the phone kept last time), can
// check in and answer, and it all goes to the practice, once, when the phone can reach it again.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:steady/services/api.dart';

final _stored = <String, String>{};

String _token() {
  String part(Map<String, Object> m) => base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${part({'alg': 'HS256', 'typ': 'JWT'})}.${part({'id': 'u1', 'type': 'auth', 'exp': 4102444800})}.sig';
}

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

Map<String, Object> _list(List<Object> items) => {'page': 1, 'perPage': 500, 'totalItems': items.length, 'totalPages': 1, 'items': items};

const _phq = {
  'id': 'inst_phq9000000', 'collectionId': 'c', 'collectionName': 'instruments', 'key': 'phq9', 'name': 'PHQ-9',
  'kind': 'questionnaire', 'licenceStatus': 'cleared', 'active': true, 'definition': {'items': []},
};
const _box = {
  'id': 'inst_box0000000', 'collectionId': 'c', 'collectionName': 'instruments', 'key': 'box-breathing', 'name': 'Box breathing',
  'kind': 'exercise', 'licenceStatus': 'cleared', 'active': true, 'definition': {'summary': 'Four slow counts'},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    _stored.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), (call) async {
      final args = (call.arguments as Map?) ?? const {};
      final key = '${args['key']}';
      switch (call.method) {
        case 'read':
          return _stored[key];
        case 'write':
          _stored[key] = '${args['value']}';
          return null;
        case 'delete':
          _stored.remove(key);
          return null;
        case 'containsKey':
          return _stored.containsKey(key);
        case 'readAll':
          return Map<String, String>.from(_stored);
      }
      return null;
    });
  });

  test('offline: the copy kept last time, answers kept and sent once the practice is back', () async {
    _stored['steady.server'] = 'https://steady.test';
    var up = true;
    final posts = <http.Request>[];
    final now = DateTime.now().toUtc().toIso8601String().replaceFirst('T', ' ');
    final client = MockClient((req) async {
      if (!up) throw http.ClientException('no signal');
      final p = req.url.path;
      if (req.method == 'POST') {
        posts.add(req);
        return _json({'id': 'saved${posts.length}', 'status': 'done'});
      }
      if (p.endsWith('/collections/assignments/records')) {
        return _json(_list([
          {'id': 'asg_one00000000', 'collectionId': 'c', 'collectionName': 'assignments', 'patient': 'u1', 'status': 'pending',
            'instrument': _phq['id']!, 'created': now, 'availableFrom': '', 'expand': {'instrument': _phq}},
        ]));
      }
      if (p.endsWith('/collections/checkins/records')) {
        return _json(_list([
          {'id': 'ck_old00000000', 'collectionId': 'c', 'collectionName': 'checkins', 'patient': 'u1', 'mood': 4, 'anxiety': 2,
            'sleep': 3, 'energy': 3, 'note': 'my private words', 'created': '2020-01-01 00:00:00.000Z',
            'answeredAt': now},
        ]));
      }
      if (p.endsWith('/collections/instruments/records')) return _json(_list([_phq, _box]));
      return _json({'message': 'Not found.'}, 404);
    });
    final api = await Api.create(httpClient: () => client);
    api.pb.authStore.save(_token(), RecordModel.fromJson({'id': 'u1', 'collectionId': '_pb_users_auth_', 'collectionName': 'users', 'role': 'patient', 'name': 'Lee'}));

    // online: fresh, and a copy kept on the phone without the words of any check-in
    final fresh = await api.patientHome();
    expect(fresh.offlineSince, isNull);
    expect(fresh.pending.single.name, 'PHQ-9');
    expect(fresh.recent.single.mood, 4, reason: 'filed by when it was answered, not when it arrived');
    expect(fresh.exercises.map((i) => i.key), ['box-breathing']);
    expect(_stored['steady.home.u1'], isNotNull);
    expect(_stored['steady.home.u1'], isNot(contains('my private words')));

    // no signal: the check-in and the questionnaire are kept on the phone
    up = false;
    expect(await api.addCheckin(mood: 2, anxiety: 4, sleep: 2, energy: 2, note: 'rough'), isFalse);
    expect(await api.completeQuestionnaire('asg_one00000000', {'phq9_1': 1}, title: 'PHQ-9'), isFalse);
    expect(api.outbox.waiting, 2);
    final off = await api.patientHome();
    expect(off.offlineSince, isNotNull);
    expect(off.pending, isEmpty, reason: 'answered on the phone');
    expect(off.recent.first.mood, 2, reason: 'the check-in kept on the phone counts as today\'s');
    expect(off.exercises.single.name, 'Box breathing');

    // back: sent first, in order, with the phone's ids; then the screen is fresh again
    up = true;
    final back = await api.patientHome();
    expect(back.offlineSince, isNull);
    expect(api.outbox.waiting, 0);
    expect(posts.map((r) => r.url.path).toList(), ['/api/collections/checkins/records', '/api/steady/assignments/asg_one00000000/complete']);
    final ck = jsonDecode(posts[0].body) as Map;
    expect(ck['clientId'], matches(RegExp(r'^[a-z0-9]{15}$')));
    expect(ck['patient'], 'u1');
    expect(ck['note'], 'rough');
    final q = jsonDecode(posts[1].body) as Map;
    expect(q['answers'], {'phq9_1': 1});
    expect(q['clientId'], isNot(ck['clientId']));

    // signing out deletes what the phone kept
    up = false;
    await api.addCheckin(mood: 3, anxiety: 3, sleep: 3, energy: 3);
    await api.forgetPatientCopies();
    expect(_stored.keys.where((k) => k.startsWith('steady.home.') || k.startsWith('steady.outbox.')), isEmpty);
  });

  test('a refusal is still shown at once: only an unreachable practice keeps answers', () async {
    _stored['steady.server'] = 'https://steady.test';
    final client = MockClient((req) async => _json({'message': 'Please answer all four questions.', 'data': {}}, 400));
    final api = await Api.create(httpClient: () => client);
    api.pb.authStore.save(_token(), RecordModel.fromJson({'id': 'u1', 'collectionId': '_pb_users_auth_', 'collectionName': 'users', 'role': 'patient'}));
    await expectLater(api.addCheckin(mood: 9, anxiety: 3, sleep: 3, energy: 3), throwsA(isA<ClientException>()));
    expect(api.outbox.waiting, 0);
    // and without a copy on the phone, an unreachable practice is an error as before
    final down = await Api.create(httpClient: () => MockClient((req) async => throw http.ClientException('no signal')));
    down.pb.authStore.save(_token(), RecordModel.fromJson({'id': 'u2', 'collectionId': '_pb_users_auth_', 'collectionName': 'users', 'role': 'patient'}));
    await expectLater(down.patientHome(), throwsA(predicate((Object? e) => e != null && isUnreachable(e))));
  });
}
