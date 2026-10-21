// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pocketbase/pocketbase.dart';

import '../models.dart';

/// Server address. Practice builds set it at build time:
///   flutter build appbundle --dart-define=STEADY_SERVER=https://steady.yourpractice.co.za
/// Without it, the web app uses the address it was loaded from, and the phone app
/// asks for an address on first launch (handy for testing through a tunnel).
const kServerUrl = String.fromEnvironment('STEADY_SERVER');

const _authKey = 'steady.auth';
const _serverKey = 'steady.server';

/// Returns a clean https://host[:port] address, or null if it isn't usable.
String? normaliseServerUrl(String input) {
  var s = input.trim();
  if (s.isEmpty) return null;
  if (!s.contains('://')) s = 'https://$s';
  final u = Uri.tryParse(s);
  if (u == null || u.host.isEmpty || !(u.scheme == 'https' || u.scheme == 'http')) return null;
  final path = u.path.replaceAll(RegExp(r'/+$'), '');
  return '${u.scheme}://${u.host}${u.hasPort ? ':${u.port}' : ''}$path';
}

/// Reads an invite QR code: `https://<server>/join?invite=<code>` (or the older
/// `https://<server>/?invite=<code>`). Returns the server address and the 8-character code,
/// or null if it isn't a Steady invite.
({String server, String code})? parseInviteLink(String raw) {
  final u = Uri.tryParse(raw.trim());
  if (u == null || u.host.isEmpty || !(u.scheme == 'https' || u.scheme == 'http')) return null;
  final code = (u.queryParameters['invite'] ?? '').toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  if (code.length != 8) return null;
  final path = u.path.replaceAll(RegExp(r'/+$'), '').replaceAll(RegExp(r'/join$'), '');
  final server = normaliseServerUrl('${u.scheme}://${u.host}${u.hasPort ? ':${u.port}' : ''}$path');
  return server == null ? null : (server: server, code: code);
}

/// The link an invite QR code carries. Scanned in the Steady app, it connects and fills in
/// the code; scanned with a phone camera, the server's /join page offers the Android app
/// (or, on an iPhone, opens the web app with the code filled in).
String inviteLink(String serverUrl, String code) =>
    '${serverUrl.replaceAll(RegExp(r'/+$'), '')}/join?invite=${code.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '')}';

/// Turns any error into a sentence a person can act on.
String errorText(Object error) {
  if (error is FormatException) return error.message;
  if (error is ClientException) {
    if (error.statusCode == 0) return "Can't reach the server. Check your connection and try again.";
    final r = error.response;
    final msg = '${r['message'] ?? ''}'.trim();
    final details = asList(asMap(r['data'])['errors']).map((e) => '$e').toList();
    if (details.isNotEmpty) return [if (msg.isNotEmpty) msg, ...details.take(6)].join('\n');
    if (error.statusCode == 400 && r['data'] is Map && (r['data'] as Map).isNotEmpty && msg.isEmpty) {
      return 'Please check the details and try again.';
    }
    if (msg.isNotEmpty) return msg;
    if (error.statusCode == 401 || error.statusCode == 403) return 'Please sign in again.';
    return 'Something went wrong (${error.statusCode}). Please try again.';
  }
  return 'Something went wrong. Please try again.';
}

/// Password accepted; the account uses two-step sign-in, so ask for the 6-digit code.
class TwoStepNeeded implements Exception {
  const TwoStepNeeded();
}

/// Someone at the practice, with what an administrator may see: name and role only.
class Person {
  final String id, name, role, email;
  final bool active, master, serverAdmin, twoStep;
  final String clinicianId, clinicianName;
  final DateTime? joinedAt;
  Person({
    required this.id,
    required this.name,
    required this.role,
    this.email = '',
    this.active = true,
    this.master = false,
    this.serverAdmin = false,
    this.twoStep = false,
    this.clinicianId = '',
    this.clinicianName = '',
    this.joinedAt,
  });
  factory Person.fromJson(Map<String, dynamic> j) {
    final c = asMap(j['clinician']);
    return Person(
      id: '${j['id']}',
      name: '${j['name'] ?? ''}',
      role: '${j['role'] ?? ''}',
      email: '${j['email'] ?? ''}',
      active: j['active'] == true,
      master: j['master'] == true,
      serverAdmin: j['serverAdmin'] == true,
      twoStep: j['twoStep'] == true,
      clinicianId: '${c['id'] ?? ''}',
      clinicianName: '${c['name'] ?? ''}',
      joinedAt: fromMs(j['joinedAt']),
    );
  }
}

class Api {
  final PocketBase pb;
  final FlutterSecureStorage _storage;
  Api._(this.pb, this._storage);

  static Future<Api> create({FlutterSecureStorage storage = const FlutterSecureStorage()}) async {
    String? initial;
    String? saved;
    try {
      initial = await storage.read(key: _authKey);
      saved = await storage.read(key: _serverKey);
    } catch (_) {
      initial = null; // e.g. keychain unavailable after restore; user signs in again
    }
    final store = AsyncAuthStore(
      save: (data) => storage.write(key: _authKey, value: data),
      initial: initial,
      clear: () => storage.delete(key: _authKey),
    );
    final url = kServerUrl.isNotEmpty
        ? kServerUrl
        : (saved != null && saved.isNotEmpty)
            ? saved
            : kIsWeb
                ? Uri.base.origin
                : '';
    return Api._(PocketBase(url, authStore: store), storage);
  }

  /// Fixed at build time, so the server can't be changed in the app.
  bool get serverLocked => kServerUrl.isNotEmpty;
  bool get hasServer => pb.baseURL.isNotEmpty;
  String get serverUrl => pb.baseURL;

  /// Checks the address answers as a Steady server, then switches to it and signs out.
  Future<void> setServer(String input) async {
    final url = normaliseServerUrl(input);
    if (url == null) throw const FormatException('That doesn\'t look like a web address.');
    final probe = PocketBase(url);
    try {
      final res = await probe.send<Map<String, dynamic>>('/api/steady/config');
      if (res['crisisLines'] == null) throw const FormatException('That server isn\'t running Steady.');
    } on ClientException catch (e) {
      throw FormatException(e.statusCode == 0
          ? 'Couldn\'t reach $url. Check the address and that the server is running.'
          : 'That server isn\'t running Steady (${e.statusCode}).');
    } finally {
      probe.close();
    }
    pb.authStore.clear();
    pb.baseURL = url;
    await _storage.write(key: _serverKey, value: url);
  }

  RecordModel? get me => pb.authStore.record;
  bool get signedIn => pb.authStore.isValid && me != null;
  String get myId => me?.id ?? '';
  String get role => me?.getStringValue('role') ?? '';
  String get myName => me?.getStringValue('name') ?? '';
  int get tzOffset => DateTime.now().timeZoneOffset.inMinutes;
  bool get wearableConnected => (me?.getStringValue('wearableConsentAt') ?? '').isNotEmpty;
  String get privacyNoticeVersion => me?.getStringValue('privacyNoticeVersion') ?? '';

  /* ---------------- session ---------------- */

  Future<AppConfig> config() async => AppConfig.fromJson(await pb.send<Map<String, dynamic>>('/api/steady/config'));

  /// Throws [TwoStepNeeded] when the password is right but a code is needed.
  Future<void> signIn(String email, String password, {String? code}) async {
    if (code == null) {
      try {
        await pb.collection('users').authWithPassword(email.trim(), password);
      } on ClientException catch (e) {
        if (e.statusCode == 400 && '${asMap(asMap(e.response['data'])['twoStep'])['code']}' == 'two_step') throw const TwoStepNeeded();
        rethrow;
      }
      return;
    }
    final res = await pb.send<Map<String, dynamic>>('/api/steady/auth/sign-in',
        method: 'POST', body: {'email': email.trim(), 'password': password, 'code': code.trim()});
    _saveAuth(res);
  }

  void _saveAuth(Map<String, dynamic> res) =>
      pb.authStore.save('${res['token']}', RecordModel.fromJson(asMap(res['record'])));

  bool get mustChangePassword => me?.getBoolValue('mustChangePassword') ?? false;
  bool get twoStepOn => (me?.getStringValue('totpEnabledAt') ?? '').isNotEmpty;
  bool get isMaster => role == 'clinician' && (me?.getBoolValue('master') ?? false);
  bool get isStaff => role == 'clinician' || role == 'admin';

  /// Choose a new password (also the way out of a temporary one).
  Future<void> changePassword(String current, String next) async {
    final res = await pb.send<Map<String, dynamic>>('/api/steady/me/password',
        method: 'POST', body: {'password': current, 'newPassword': next});
    _saveAuth(res);
  }

  /// Two-step sign-in: a new secret and the otpauth:// address for the QR code.
  Future<({String secret, String uri})> twoStepStart() async {
    final res = await pb.send<Map<String, dynamic>>('/api/steady/me/two-step/start', method: 'POST');
    return (secret: '${res['secret']}', uri: '${res['uri']}');
  }

  /// Confirms with the first code; returns the one-time recovery codes.
  Future<List<String>> twoStepConfirm(String code) async {
    final res = await pb.send<Map<String, dynamic>>('/api/steady/me/two-step/confirm', method: 'POST', body: {'code': code.trim()});
    await pb.collection('users').authRefresh();
    return asList(res['recoveryCodes']).map((c) => '$c').toList();
  }

  Future<void> twoStepOff(String password) async {
    await pb.send('/api/steady/me/two-step/off', method: 'POST', body: {'password': password});
    await pb.collection('users').authRefresh();
  }

  /// Patients: who at the practice can see what they send.
  Future<({String clinician, List<String> shared})> careTeam() async {
    final res = await pb.send<Map<String, dynamic>>('/api/steady/me/care-team');
    return (
      clinician: '${asMap(res['clinician'])['name'] ?? ''}',
      shared: asList(res['sharedWith']).map((x) => '${asMap(x)['name']}').toList(),
    );
  }

  Future<void> join({
    required String code,
    required String name,
    required String email,
    required String password,
    required bool consent,
  }) async {
    final res = await pb.send<Map<String, dynamic>>('/api/steady/join', method: 'POST', body: {
      'code': code,
      'name': name,
      'email': email,
      'password': password,
      'consent': consent,
      'tzOffset': tzOffset,
    });
    pb.authStore.save('${res['token']}', RecordModel.fromJson(asMap(res['record'])));
  }

  /// Refreshes the token and the user's record (role, name, active).
  Future<void> refresh() async {
    if (!pb.authStore.isValid) return;
    await pb.collection('users').authRefresh();
    final stored = me?.getIntValue('tzOffset');
    if (stored != tzOffset) {
      try {
        await pb.collection('users').update(myId, body: {'tzOffset': tzOffset});
      } catch (_) {/* not important */}
    }
  }

  void signOut() => pb.authStore.clear();

  String? _deviceToken;

  /// Removes this phone's push registration, so a signed-out account gets no more
  /// notifications here. Call before [signOut].
  Future<void> forgetThisDevice() async {
    final t = _deviceToken;
    if (!signedIn || t == null) return;
    try {
      final list = await pb.collection('devices').getList(perPage: 5, filter: pb.filter('token = {:t}', {'t': t}));
      for (final d in list.items) {
        await pb.collection('devices').delete(d.id);
      }
    } catch (_) {/* best effort; the server drops dead registrations */}
    _deviceToken = null;
  }

  /* ---------------- shared ---------------- */

  Future<List<Instrument>> instruments({bool includeArchived = false}) async {
    final list = await pb.collection('instruments').getFullList(
          filter: includeArchived ? null : 'active = true',
          sort: 'kind,name',
        );
    return list.map(Instrument.fromRecord).toList();
  }

  Future<Instrument> instrument(String id) async => Instrument.fromRecord(await pb.collection('instruments').getOne(id));

  Future<void> registerDevice({
    required String platform,
    required String provider,
    required String token,
    bool sandbox = false,
  }) async {
    if (!signedIn) return;
    _deviceToken = token;
    final body = {'user': myId, 'platform': platform, 'provider': provider, 'token': token, 'sandbox': sandbox};
    try {
      final existing = await pb.collection('devices').getList(
            perPage: 1,
            filter: pb.filter('token = {:t}', {'t': token}),
          );
      if (existing.items.isNotEmpty) {
        await pb.collection('devices').update(existing.items.first.id, body: {'sandbox': sandbox, 'platform': platform});
      } else {
        await pb.collection('devices').create(body: body);
      }
    } catch (_) {
      // The token may belong to another account on this phone (shared device). Ignore;
      // push is a convenience and the app still shows everything when opened.
    }
  }

  Future<List<AppNotification>> notifications() async {
    final res = await pb.collection('notifications').getList(perPage: 60, sort: '-created');
    return res.items.map(AppNotification.fromRecord).toList();
  }

  Future<void> markRead(String id) => pb.collection('notifications').update(id, body: {'read': true});

  Future<void> markAllRead(List<AppNotification> items) async {
    for (final n in items.where((n) => !n.read)) {
      await markRead(n.id);
    }
  }

  /// Live updates while the app is open. Returns a function that stops them.
  Future<UnsubscribeFunc> watchNotifications(void Function(AppNotification n) onNew) {
    return pb.collection('notifications').subscribe('*', (e) {
      if (e.action == 'create' && e.record != null) onNew(AppNotification.fromRecord(e.record!));
    });
  }

  /// kind: privacy | wearable. Refreshes the account afterwards so its consent fields are current.
  Future<void> setConsent(String kind, String version, {bool accepted = true}) async {
    await pb.send('/api/steady/consent', method: 'POST', body: {'kind': kind, 'version': version, 'accepted': accepted});
    await pb.collection('users').authRefresh();
  }

  /* ---------------- patient ---------------- */

  Future<void> addCheckin({required int mood, required int anxiety, required int sleep, required int energy, String note = ''}) async {
    await pb.collection('checkins').create(body: {
      'patient': myId,
      'mood': mood,
      'anxiety': anxiety,
      'sleep': sleep,
      'energy': energy,
      'note': note,
    });
  }

  Future<List<Checkin>> myCheckins({int days = 14}) => checkinsFor(myId, days: days);

  Future<List<Assignment>> myPending() async {
    final list = await pb.collection('assignments').getFullList(
          filter: pb.filter('patient = {:p} && status = "pending"', {'p': myId}),
          sort: '-created',
          expand: 'instrument',
        );
    return list.map(Assignment.fromRecord).where((a) => a.available).toList();
  }

  Future<void> completeQuestionnaire(String assignmentId, Map<String, Object?> answers) =>
      pb.send('/api/steady/assignments/$assignmentId/complete', method: 'POST', body: {'answers': answers});

  Future<void> completeExercise(String assignmentId, Map<String, Object?> result) =>
      pb.send('/api/steady/assignments/$assignmentId/complete', method: 'POST', body: {'result': result});

  Future<void> selfStart(String instrumentId, Map<String, Object?> result) =>
      pb.send('/api/steady/self-start', method: 'POST', body: {'instrument': instrumentId, 'result': result});

  Future<void> uploadBiometrics(List<Map<String, Object>> days,
      {required String platform, required String source, required String algorithm}) async {
    await pb.send('/api/steady/biometrics', method: 'POST', body: {
      'days': days,
      'platform': platform,
      'source': source,
      'algorithm': algorithm,
    });
  }

  /* ---------------- clinician ---------------- */

  Future<List<PatientSummary>> overview() async {
    final res = await pb.send<Map<String, dynamic>>('/api/steady/overview');
    return asList(res['patients']).map((p) => PatientSummary.fromJson(asMap(p))).toList();
  }

  Future<PatientSummary> patientSummary(String patientId) async =>
      PatientSummary.fromJson(await pb.send<Map<String, dynamic>>('/api/steady/patients/$patientId/summary'));

  Future<List<Checkin>> checkinsFor(String patientId, {int days = 14}) async {
    final since = DateTime.now().toUtc().subtract(Duration(days: days)).toIso8601String().replaceFirst('T', ' ');
    final res = await pb.collection('checkins').getList(
          perPage: 200,
          sort: '-created',
          filter: pb.filter('patient = {:p} && created >= {:s}', {'p': patientId, 's': since}),
        );
    return res.items.map(Checkin.fromRecord).toList();
  }

  Future<List<Assignment>> assignmentsFor(String patientId) async {
    final res = await pb.collection('assignments').getList(
          perPage: 60,
          sort: '-created',
          expand: 'instrument',
          filter: pb.filter('patient = {:p} && status != "cancelled"', {'p': patientId}),
        );
    return res.items.map(Assignment.fromRecord).toList();
  }

  Future<Assignment> assignment(String id) async =>
      Assignment.fromRecord(await pb.collection('assignments').getOne(id, expand: 'instrument'));

  /// Daily watch values and the patient's own usual range. Dates are YYYY-MM-DD.
  Future<Biometrics> patientBiometrics(String patientId, {String? from, String? to}) async {
    final res = await pb.send<Map<String, dynamic>>('/api/steady/patients/$patientId/biometrics', query: {
      'from': ?from,
      'to': ?to,
    });
    return Biometrics.fromJson(res);
  }

  Future<void> assign({required String patientId, required String instrumentId, String note = '', String repeat = 'once'}) async {
    await pb.collection('assignments').create(body: {
      'patient': patientId,
      'clinician': myId,
      'instrument': instrumentId,
      'note': note,
      'repeat': repeat,
    });
  }

  Future<void> cancelAssignment(String id) => pb.send('/api/steady/assignments/$id/cancel', method: 'POST');

  Future<({String code, DateTime expires})> createInvite(String label) async {
    final res = await pb.send<Map<String, dynamic>>('/api/steady/invites', method: 'POST', body: {'label': label});
    return (code: '${res['code']}', expires: fromMs(res['expiresAt']) ?? DateTime.now());
  }

  bool get isServerAdmin => me?.getBoolValue('serverAdmin') ?? false;

  /* ---------------- the practice (master clinician, administrator) ---------------- */

  /// A temporary password for someone; they must choose their own at next sign-in.
  Future<String> resetPassword(String userId, {bool twoStep = false}) async {
    final res = await pb.send<Map<String, dynamic>>('/api/steady/people/$userId/reset-password',
        method: 'POST', body: {'twoStep': twoStep});
    return '${res['temporaryPassword']}';
  }

  Future<({List<Person> patients, List<Person> clinicians, List<Person> admins})> people() async {
    final res = await pb.send<Map<String, dynamic>>('/api/steady/admin/people');
    List<Person> list(Object? v) => asList(v).map((p) => Person.fromJson(asMap(p))).toList();
    return (patients: list(res['patients']), clinicians: list(res['clinicians']), admins: list(res['admins']));
  }

  /// Active psychologists (names only).
  Future<List<({String id, String name, bool you})>> clinicians() async {
    final res = await pb.send<Map<String, dynamic>>('/api/steady/clinicians');
    return asList(res['clinicians']).map((raw) {
      final j = asMap(raw);
      return (id: '${j['id']}', name: '${j['name']}', you: j['you'] == true);
    }).toList();
  }

  Future<({String code, DateTime expires})> createInviteFor(String clinicianId, String label) async {
    final res = await pb.send<Map<String, dynamic>>('/api/steady/admin/invites',
        method: 'POST', body: {'label': label, 'clinician': clinicianId});
    return (code: '${res['code']}', expires: fromMs(res['expiresAt']) ?? DateTime.now());
  }

  Future<void> reassignPatient(String patientId, String clinicianId) =>
      pb.send('/api/steady/admin/patients/$patientId/reassign', method: 'POST', body: {'clinician': clinicianId});

  Future<void> setActive(String userId, bool active) =>
      pb.send('/api/steady/admin/people/$userId/active', method: 'POST', body: {'active': active});

  /// role: clinician | admin. Returns the temporary password.
  Future<String> createStaff({required String role, required String name, required String email}) async {
    final res = await pb.send<Map<String, dynamic>>('/api/steady/admin/people',
        method: 'POST', body: {'role': role, 'name': name, 'email': email});
    return '${res['temporaryPassword']}';
  }

  /* ---------------- sharing and exports ---------------- */

  Future<List<({String id, String name, bool shared})>> sharing(String patientId) async {
    final res = await pb.send<Map<String, dynamic>>('/api/steady/patients/$patientId/sharing');
    return asList(res['colleagues']).map((raw) {
      final j = asMap(raw);
      return (id: '${j['id']}', name: '${j['name']}', shared: j['shared'] == true);
    }).toList();
  }

  Future<void> share(String patientId, String clinicianId, bool shared) =>
      pb.send('/api/steady/patients/$patientId/share', method: 'POST', body: {'clinician': clinicianId, 'shared': shared});

  /// One patient's whole record (or a date range), for a PDF or Excel export.
  Future<Map<String, dynamic>> exportPatient(String patientId, {String? from, String? to}) =>
      pb.send<Map<String, dynamic>>('/api/steady/patients/$patientId/export', query: {'from': ?from, 'to': ?to});

  /// All of this psychologist's own patients.
  Future<Map<String, dynamic>> exportAll() => pb.send<Map<String, dynamic>>('/api/steady/export');

  /// Server and updates (server admins): status from deploy/ctl/steady-ctl.sh.
  Future<Map<String, dynamic>> systemStatus() => pb.send<Map<String, dynamic>>('/api/steady/system');

  /// Asks the server to 'check' for or install an 'update'.
  Future<void> systemRequest(String action) =>
      pb.send('/api/steady/system/request', method: 'POST', body: {'action': action});

  /// Renames a patient on the psychologist's screens; returns the name now shown.
  Future<String> setPatientLabel(String id, String label) async {
    final res = await pb.send<Map<String, dynamic>>('/api/steady/patients/$id/label', method: 'POST', body: {'label': label});
    return '${res['name'] ?? label}';
  }

  Future<void> deactivatePatient(String id) => pb.send('/api/steady/patients/$id/deactivate', method: 'POST');

  Future<String> createInstrument(Map<String, dynamic> definition) async {
    final res = await pb.send<Map<String, dynamic>>('/api/steady/instruments', method: 'POST', body: {'definition': definition});
    return '${res['id']}';
  }

  Future<void> updateInstrument(String id, Map<String, dynamic> definition) =>
      pb.send('/api/steady/instruments/$id', method: 'PUT', body: {'definition': definition});

  Future<void> archiveInstrument(String id) => pb.send('/api/steady/instruments/$id/archive', method: 'POST');

  Future<void> confirmLicence(String id) =>
      pb.send('/api/steady/instruments/$id/licence', method: 'POST', body: {'confirm': true});

  /// format: steady | fhir | reproschema
  Future<Map<String, dynamic>> importInstrument({
    required String format,
    Map<String, dynamic>? data,
    String? activity,
    bool ownWork = false,
  }) =>
      pb.send<Map<String, dynamic>>('/api/steady/instruments/import', method: 'POST', body: {
        'format': format,
        'data': ?data,
        'activity': ?activity,
        'ownWork': ownWork,
      });

  Future<List<({String activity, String label, String status, bool imported})>> reproCatalog() async {
    final res = await pb.send<Map<String, dynamic>>('/api/steady/reproschema/catalog');
    return asList(res['items']).map((raw) {
      final j = asMap(raw);
      return (
        activity: '${j['activity']}',
        label: '${j['label']}',
        status: '${j['status']}',
        imported: j['imported'] == true,
      );
    }).toList();
  }
}
