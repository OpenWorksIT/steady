// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Reads the watch data from the phone's health store, summarises it per day and uploads
// the summaries. Runs when the app opens and when the patient taps "Sync now".
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../services/api.dart';
import 'health_source.dart';
import 'summary.dart';

const wearableConsentVersion = 'wearable-1';

class SyncResult {
  final int days;
  final DateTime at;
  const SyncResult(this.days, this.at);
}

class WearableSync {
  WearableSync._();
  static final instance = WearableSync._();

  final HealthStore? store = createHealthStore();
  final _storage = const FlutterSecureStorage();
  Future<SyncResult?>? _running;

  bool get supported => store != null;

  String _key(Api api, String what) => 'steady.wearable.$what.${api.myId}';

  Future<DateTime?> lastSync(Api api) async {
    try {
      final v = await _storage.read(key: _key(api, 'at'));
      return v == null ? null : DateTime.tryParse(v);
    } catch (_) {
      return null;
    }
  }

  /// Connects: asks for health-store access, records consent, then fetches up to 30 days.
  /// Returns an error message for the person, or null on success.
  Future<String?> connect(Api api) async {
    final s = store;
    if (s == null) return 'Watch data can only be shared from the Steady app on a phone.';
    final st = await s.status();
    if (st == StoreStatus.notInstalled || st == StoreStatus.updateRequired) {
      await s.openInstall();
      return st == StoreStatus.notInstalled
          ? '${s.name} needs to be installed first. Install it, then tap Connect again.'
          : '${s.name} needs an update. Update it, then tap Connect again.';
    }
    final granted = await s.requestAccess();
    if (!granted) return 'Steady wasn\'t given access. You can allow it in ${s.name} and try again.';
    await api.setConsent('wearable', wearableConsentVersion, accepted: true);
    await sync(api, full: true);
    return null;
  }

  Future<void> disconnect(Api api) async {
    await api.setConsent('wearable', wearableConsentVersion, accepted: false);
    try {
      await _storage.delete(key: _key(api, 'last'));
      await _storage.delete(key: _key(api, 'at'));
    } catch (_) {}
  }

  /// Safe to call often: only one sync runs at a time, and it re-reads the last 2 days.
  Future<SyncResult?> sync(Api api, {bool full = false}) {
    return _running ??= _sync(api, full).whenComplete(() => _running = null);
  }

  Future<SyncResult?> _sync(Api api, bool full) async {
    final s = store;
    if (s == null || !api.wearableConnected) return null;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    var from = today.subtract(const Duration(days: 29));
    if (!full) {
      String? last;
      try {
        last = await _storage.read(key: _key(api, 'last'));
      } catch (_) {}
      final lastDay = last == null ? null : DateTime.tryParse(last);
      if (lastDay != null) {
        final resume = lastDay.subtract(const Duration(days: 2));
        if (resume.isAfter(from)) from = resume;
      }
    }

    // sleep and blood oxygen are small: read the whole span once
    final wide = await s.sleepAndOxygen(from.subtract(const Duration(hours: 18)), now);
    final summaries = <Map<String, Object>>[];
    for (var d = from; !d.isAfter(today); d = DateTime(d.year, d.month, d.day + 1)) {
      final next = DateTime(d.year, d.month, d.day + 1);
      // heart rate can be dense: read a day at a time, from the evening before
      final hr = await s.heartRate(d.subtract(const Duration(hours: 14)), next.isAfter(now) ? now : next);
      int? steps;
      try {
        steps = await s.steps(d, next.isAfter(now) ? now : next);
      } catch (_) {}
      final values = summariseDay(DayReadings(
        dayStart: d,
        hr: hr,
        sleep: wide.sleep,
        spo2: wide.spo2,
        steps: (steps ?? 0) > 0 ? steps : null,
      ));
      if (values.isNotEmpty) summaries.add({'day': dayKey(d), 'values': values});
    }

    for (var i = 0; i < summaries.length; i += 31) {
      await api.uploadBiometrics(
        summaries.sublist(i, i + 31 > summaries.length ? summaries.length : i + 31),
        platform: s.platform,
        source: s.name,
        algorithm: rhrAlgorithm,
      );
    }
    try {
      await _storage.write(key: _key(api, 'last'), value: dayKey(today));
      await _storage.write(key: _key(api, 'at'), value: now.toIso8601String());
    } catch (_) {}
    return SyncResult(summaries.length, now);
  }
}
