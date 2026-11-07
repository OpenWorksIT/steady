// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Answers a patient gives while Steady can't reach the practice (no signal, the server
// restarting) are kept on the phone and sent, oldest first, as soon as it can: check-ins,
// questionnaires, exercises the psychologist sent and exercises the patient started.
//
// Each answer carries the phone's own id for it, so one that was sent twice (the reply was lost)
// is stored once, and how long it waited, so the practice files it at the time it was given.
// Kept in the phone's secure storage, for this account only, and deleted when the patient signs
// out. Not in the web app: a browser has no safe place to keep them.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart' show ClientException;

/// True when the practice couldn't be reached (no answer, a timeout, or the server busy or
/// restarting), as opposed to the server answering no.
bool isUnreachable(Object e) {
  if (e is TimeoutException || e is http.ClientException) return true;
  if (e is ClientException) {
    final s = e.statusCode;
    return s == 0 || s == 429 || s == 502 || s == 503 || s == 504;
  }
  return false;
}

/// One answer waiting to be sent.
class OutboxItem {
  /// checkin | questionnaire | exercise | selfstart
  final String kind;

  /// The phone's own id for it: 15 of a-z and 0-9.
  final String id;

  /// When it was answered (this phone's clock, ms).
  final int at;

  /// The assignment (questionnaire, exercise) or instrument (selfstart) it belongs to; '' for a check-in.
  final String target;

  /// What to call it on screen ("Check-in", "PHQ-9").
  final String title;

  /// What's sent: the check-in's fields, {'answers': …} or {'result': …}.
  final Map<String, Object?> body;

  const OutboxItem({required this.kind, required this.id, required this.at, required this.target, required this.title, required this.body});

  static final _rand = Random.secure();
  static const _alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';

  /// A new id the way the server expects it.
  static String newId() => List.generate(15, (_) => _alphabet[_rand.nextInt(_alphabet.length)]).join();

  Map<String, Object?> toJson() => {'kind': kind, 'id': id, 'at': at, 'target': target, 'title': title, 'body': body};

  static OutboxItem? fromJson(Object? j) {
    if (j is! Map) return null;
    final kind = '${j['kind'] ?? ''}';
    final id = '${j['id'] ?? ''}';
    final at = j['at'];
    final body = j['body'];
    if (!const ['checkin', 'questionnaire', 'exercise', 'selfstart'].contains(kind) || !RegExp(r'^[a-z0-9]{15}$').hasMatch(id) || at is! num || body is! Map) {
      return null;
    }
    return OutboxItem(kind: kind, id: id, at: at.toInt(), target: '${j['target'] ?? ''}', title: '${j['title'] ?? ''}', body: Map<String, Object?>.from(body));
  }
}

/// Where the outbox keeps its items (the phone's secure storage; memory in tests).
abstract class OutboxStore {
  Future<String?> read(String key);
  Future<void> write(String key, String? value);
}

class MemoryOutboxStore implements OutboxStore {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}

/// Sends one item. [waited] is how long it waited on this phone, in seconds (0 when sent straight away).
typedef OutboxDeliver = Future<void> Function(OutboxItem item, int waited);

/// An answer the practice's server refused when it was finally sent (withdrawn meanwhile, say).
class OutboxRefusal {
  final String title, message;
  final DateTime at;
  const OutboxRefusal(this.title, this.message, this.at);
}

class Outbox extends ChangeNotifier {
  /// How many answers one phone keeps for one account (about a month of daily check-ins and questionnaires).
  static const limit = 60;

  /// The server files answers that waited up to this long (lib/server.js waited()).
  static const maxWait = Duration(days: 30);

  final OutboxStore _store;
  final OutboxDeliver _deliver;
  final String Function() _user;
  final DateTime Function() _now;

  /// False in the web app: answers go straight to the server or not at all.
  final bool enabled;

  Outbox(this._store, this._deliver, this._user, {DateTime Function()? now, this.enabled = true}) : _now = now ?? DateTime.now;

  String _loadedFor = '';
  List<OutboxItem> _items = [];
  Future<void>? _flushing;

  /// Answers the server refused when they were sent at last; shown to the patient, then cleared.
  final List<OutboxRefusal> refused = [];

  /// The waiting answers, oldest first (for the account signed in now).
  List<OutboxItem> get items => List.unmodifiable(_loadedFor == _user() ? _items : const <OutboxItem>[]);
  int get waiting => items.length;

  String _key(String user) => 'steady.outbox.$user';

  Future<void> _load() async {
    final u = _user();
    if (u == _loadedFor) return;
    _items = [];
    refused.clear();
    _loadedFor = u;
    if (u.isEmpty) return;
    try {
      final raw = await _store.read(_key(u));
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw);
        if (list is List) _items = list.map(OutboxItem.fromJson).whereType<OutboxItem>().toList();
      }
    } catch (_) {
      _items = [];
    }
    notifyListeners();
  }

  Future<void> _save() async {
    if (_loadedFor.isEmpty) return;
    await _store.write(_key(_loadedFor), _items.isEmpty ? null : jsonEncode(_items.map((i) => i.toJson()).toList()));
  }

  /// Reads what this phone is keeping for the account signed in now.
  Future<void> open() => _load();

  int _waited(OutboxItem it) => max(0, (_now().millisecondsSinceEpoch - it.at) ~/ 1000);

  /// Sends [item] now. Returns true when it reached the practice, false when the practice couldn't
  /// be reached and it was kept on this phone to send later. A refusal from the server (a wrong
  /// answer, a questionnaire already done) is thrown as usual.
  Future<bool> submit(OutboxItem item) async {
    if (!enabled) {
      await _deliver(item, 0);
      return true;
    }
    await _load();
    // anything older goes first (and if it can't, the practice can't be reached: keep this too)
    if (_items.isNotEmpty) await flush();
    if (_items.isEmpty) {
      try {
        await _deliver(item, _waited(item));
        return true;
      } catch (e) {
        if (!isUnreachable(e)) rethrow;
      }
    }
    if (_items.length >= limit) {
      throw const OutboxFull();
    }
    _items.add(item);
    await _save();
    notifyListeners();
    return false;
  }

  /// Sends what's waiting, oldest first. Stops at the first one the practice can't be reached for
  /// (or when the session has expired: they go once the patient signs in again). One the server
  /// refuses is dropped and kept in [refused] to tell the patient. Returns how many were sent.
  Future<int> flush() async {
    if (!enabled) return 0;
    // one flush at a time (a timer, the app coming back and the home screen can all ask)
    while (_flushing != null) {
      await _flushing;
    }
    final done = Completer<void>();
    _flushing = done.future;
    var sent = 0;
    try {
      await _load();
      while (_items.isNotEmpty && _user() == _loadedFor) {
        final it = _items.first;
        if (_now().millisecondsSinceEpoch - it.at > maxWait.inMilliseconds) {
          _items.removeAt(0);
          refused.add(OutboxRefusal(it.title, 'It waited on this phone for more than ${maxWait.inDays} days, so it wasn\'t sent.', _now()));
          await _save();
          continue;
        }
        try {
          await _deliver(it, _waited(it));
        } catch (e) {
          if (isUnreachable(e)) break;
          if (e is ClientException && e.statusCode == 401) break; // signed out on the server: after the next sign-in
          _items.removeAt(0);
          refused.add(OutboxRefusal(it.title, _message(e), _now()));
          await _save();
          continue;
        }
        _items.removeAt(0);
        sent++;
        await _save();
      }
    } finally {
      _flushing = null;
      done.complete();
      notifyListeners();
    }
    return sent;
  }

  String _message(Object e) {
    if (e is ClientException) {
      final m = '${e.response['message'] ?? ''}'.trim();
      if (m.isNotEmpty) return m;
      return 'The practice\'s server didn\'t accept it (${e.statusCode}).';
    }
    return 'It couldn\'t be sent.';
  }

  /// The patient has seen the refusals.
  void clearRefused() {
    if (refused.isEmpty) return;
    refused.clear();
    notifyListeners();
  }

  /// Signing out: deletes what this phone kept for the account.
  Future<void> clear() async {
    await _load();
    _items = [];
    refused.clear();
    await _save();
    notifyListeners();
  }
}

/// The phone is already holding [Outbox.limit] answers for this account.
class OutboxFull implements Exception {
  const OutboxFull();
  @override
  String toString() => 'This phone is already keeping ${Outbox.limit} answers that haven\'t reached the practice. '
      'Connect to the internet to send them first.';
}
