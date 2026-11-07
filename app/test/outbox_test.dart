// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart' show ClientException;
import 'package:steady/services/outbox.dart';

/// A practice server that can be switched off, and refuses what it's told to.
class FakeServer {
  bool up = true;
  final Map<String, ClientException> refuse = {};
  final List<(String, int)> got = []; // (id, waited)
  Future<void> deliver(OutboxItem it, int waited) async {
    if (!up) throw ClientException(statusCode: 0);
    final no = refuse[it.id];
    if (no != null) throw no;
    got.add((it.id, waited));
  }
}

OutboxItem item(String id, int at, {String kind = 'checkin', String target = '', String title = 'Check-in'}) =>
    OutboxItem(kind: kind, id: id.padRight(15, '0'), at: at, target: target, title: title, body: const {'mood': 3, 'anxiety': 2, 'sleep': 3, 'energy': 3, 'note': 'x'});

void main() {
  late FakeServer server;
  late MemoryOutboxStore store;
  late int now;
  var user = 'patient1patient';
  Outbox make({bool enabled = true}) => Outbox(store, server.deliver, () => user, now: () => DateTime.fromMillisecondsSinceEpoch(now), enabled: enabled);

  setUp(() {
    server = FakeServer();
    store = MemoryOutboxStore();
    now = DateTime.utc(2026, 11, 7, 8).millisecondsSinceEpoch;
    user = 'patient1patient';
  });

  test('sent straight away when the practice can be reached', () async {
    final o = make();
    expect(await o.submit(item('a', now)), isTrue);
    expect(server.got, [('a'.padRight(15, '0'), 0)]);
    expect(o.waiting, 0);
    expect(store.values, isEmpty);
  });

  test('kept on the phone when it can\'t, and sent later with how long it waited', () async {
    final o = make();
    server.up = false;
    expect(await o.submit(item('a', now)), isFalse);
    expect(o.waiting, 1);
    expect(store.values.keys, ['steady.outbox.patient1patient']);
    // still there after the app is closed and opened again
    final again = make();
    await again.open();
    expect(again.waiting, 1);
    expect(again.items.single.body['note'], 'x');
    // three hours later the practice is back
    now += 3 * 3600 * 1000;
    server.up = true;
    expect(await again.flush(), 1);
    expect(server.got, [('a'.padRight(15, '0'), 3 * 3600)]);
    expect(again.waiting, 0);
    expect(store.values, isEmpty, reason: 'nothing left on the phone');
  });

  test('sent oldest first; a new answer waits behind older ones; stops while unreachable', () async {
    final o = make();
    server.up = false;
    await o.submit(item('a', now));
    now += 60000;
    await o.submit(item('b', now));
    expect(await o.flush(), 0);
    expect(o.waiting, 2);
    server.up = true;
    now += 60000;
    // a new one first sends what's waiting, then itself
    expect(await o.submit(item('c', now)), isTrue);
    expect(server.got.map((g) => g.$1[0]).join(), 'abc');
    expect(server.got.map((g) => g.$2).toList(), [120, 60, 0]);
  });

  test('a refusal is dropped and told; an expired session keeps everything for the next sign-in', () async {
    final o = make();
    server.up = false;
    await o.submit(item('a', now, kind: 'questionnaire', target: 'asg1', title: 'PHQ-9'));
    await o.submit(item('b', now));
    server.up = true;
    server.refuse['a'.padRight(15, '0')] = ClientException(statusCode: 400, response: {'message': 'Your psychologist withdrew this one, so your answers weren\'t sent.'});
    expect(await o.flush(), 1);
    expect(o.waiting, 0);
    expect(o.refused.single.title, 'PHQ-9');
    expect(o.refused.single.message, contains('withdrew'));
    o.clearRefused();
    expect(o.refused, isEmpty);

    server.up = false;
    await o.submit(item('c', now));
    server.up = true;
    server.refuse['c'.padRight(15, '0')] = ClientException(statusCode: 401);
    expect(await o.flush(), 0);
    expect(o.waiting, 1, reason: 'kept until the patient signs in again');
    expect(o.refused, isEmpty);
  });

  test('a server error that isn\'t about reaching it is shown at once, not kept', () async {
    final o = make();
    server.refuse['a'.padRight(15, '0')] = ClientException(statusCode: 400, response: {'message': 'Please answer all four questions.'});
    await expectLater(o.submit(item('a', now)), throwsA(isA<ClientException>()));
    expect(o.waiting, 0);
  });

  test('timeouts and a busy or restarting server count as unreachable', () {
    expect(isUnreachable(TimeoutException('slow')), isTrue);
    for (final s in [0, 429, 502, 503, 504]) {
      expect(isUnreachable(ClientException(statusCode: s)), isTrue, reason: '$s');
    }
    for (final s in [400, 401, 403, 404, 500]) {
      expect(isUnreachable(ClientException(statusCode: s)), isFalse, reason: '$s');
    }
  });

  test('each account sees only its own; signing out deletes them', () async {
    final o = make();
    server.up = false;
    await o.submit(item('a', now));
    user = 'patient2patient';
    expect(o.waiting, 0, reason: 'another account on the same phone');
    await o.open();
    expect(o.items, isEmpty);
    user = 'patient1patient';
    await o.open();
    expect(o.waiting, 1);
    await o.clear();
    expect(o.waiting, 0);
    expect(store.values, isEmpty);
  });

  test('older than 30 days: not sent, and the patient is told', () async {
    final o = make();
    server.up = false;
    await o.submit(item('a', now));
    now += const Duration(days: 31).inMilliseconds;
    server.up = true;
    expect(await o.flush(), 0);
    expect(o.waiting, 0);
    expect(o.refused.single.message, contains('30 days'));
    expect(server.got, isEmpty);
  });

  test('the phone keeps at most ${Outbox.limit}', () async {
    final o = make();
    server.up = false;
    for (var i = 0; i < Outbox.limit; i++) {
      await o.submit(item('n$i', now + i));
    }
    await expectLater(o.submit(item('over', now)), throwsA(isA<OutboxFull>()));
    expect(o.waiting, Outbox.limit);
  });

  test('two flushes at once send each answer once', () async {
    final o = make();
    server.up = false;
    await o.submit(item('a', now));
    await o.submit(item('b', now));
    server.up = true;
    final r = await Future.wait([o.flush(), o.flush(), o.flush()]);
    expect(r.reduce((a, b) => a + b), 2);
    expect(server.got.length, 2);
  });

  test('in the web app nothing is kept: it goes straight to the server or fails', () async {
    final o = make(enabled: false);
    server.up = false;
    await expectLater(o.submit(item('a', now)), throwsA(isA<ClientException>()));
    expect(o.waiting, 0);
    expect(store.values, isEmpty);
  });

  test('a damaged copy on the phone is ignored rather than breaking the app', () async {
    store.values['steady.outbox.patient1patient'] = jsonEncode([
      {'kind': 'checkin', 'id': 'short', 'at': now, 'body': {}},
      {'kind': 'other', 'id': 'a'.padRight(15, '0'), 'at': now, 'body': {}},
      item('b', now).toJson(),
    ]);
    final o = make();
    await o.open();
    expect(o.items.map((i) => i.id[0]).toList(), ['b']);
    store.values['steady.outbox.patient1patient'] = '{not json';
    user = 'x';
    await o.open();
    user = 'patient1patient';
    await o.open();
    expect(o.items, isEmpty);
  });

  test('ids are the server\'s shape', () {
    final ids = {for (var i = 0; i < 200; i++) OutboxItem.newId()};
    expect(ids.length, 200);
    expect(ids.every((id) => RegExp(r'^[a-z0-9]{15}$').hasMatch(id)), isTrue);
  });
}
