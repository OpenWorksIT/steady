// SPDX-License-Identifier: AGPL-3.0-or-later
// Phones: Health Connect (Android) or Apple Health (iOS), through the `health` package.
import 'package:flutter/foundation.dart';
import 'package:health/health.dart';

import 'health_source.dart';
import 'summary.dart';

HealthStore? createHealthStore() {
  if (kIsWeb) return null;
  if (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) {
    return _PluginStore();
  }
  return null;
}

class _PluginStore implements HealthStore {
  final Health _h = Health();
  bool _configured = false;

  bool get _android => defaultTargetPlatform == TargetPlatform.android;

  @override
  String get name => _android ? 'Health Connect' : 'Apple Health';

  @override
  String get platform => _android ? 'android' : 'ios';

  static const _sleepTypes = [
    HealthDataType.SLEEP_SESSION,
    HealthDataType.SLEEP_ASLEEP,
    HealthDataType.SLEEP_LIGHT,
    HealthDataType.SLEEP_DEEP,
    HealthDataType.SLEEP_REM,
    HealthDataType.SLEEP_AWAKE,
  ];

  List<HealthDataType> get _types => [
        HealthDataType.HEART_RATE,
        HealthDataType.STEPS,
        HealthDataType.BLOOD_OXYGEN,
        ..._sleepTypes,
      ].where(_h.isDataTypeAvailable).toList();

  Future<void> _configure() async {
    if (_configured) return;
    await _h.configure();
    _configured = true;
  }

  @override
  Future<StoreStatus> status() async {
    if (!_android) return StoreStatus.ready;
    final s = await _h.getHealthConnectSdkStatus();
    return switch (s) {
      HealthConnectSdkStatus.sdkAvailable => StoreStatus.ready,
      HealthConnectSdkStatus.sdkUnavailableProviderUpdateRequired => StoreStatus.updateRequired,
      _ => StoreStatus.notInstalled,
    };
  }

  @override
  Future<void> openInstall() => _h.installHealthConnect();

  @override
  Future<bool> requestAccess() async {
    await _configure();
    final ok = await _h.requestAuthorization(_types);
    if (_android && ok) {
      // lets us read back further than 30 days; fine if the person says no
      try {
        await _h.requestHealthDataHistoryAuthorization();
      } catch (_) {}
    }
    return ok;
  }

  @override
  Future<bool?> hasAccess() async {
    if (!_android) return null;
    try {
      await _configure();
      return await _h.hasPermissions(_types);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<HrSample>> heartRate(DateTime from, DateTime to) async {
    await _configure();
    final points = await _h.getHealthDataFromTypes(types: const [HealthDataType.HEART_RATE], startTime: from, endTime: to);
    final out = <HrSample>[];
    for (final p in _h.removeDuplicates(points)) {
      final v = p.value;
      if (v is NumericHealthValue) out.add(HrSample(p.dateFrom.toLocal(), v.numericValue.toDouble()));
    }
    return out;
  }

  @override
  Future<StoreReadings> sleepAndOxygen(DateTime from, DateTime to) async {
    await _configure();
    final types = [HealthDataType.BLOOD_OXYGEN, ..._sleepTypes].where(_h.isDataTypeAvailable).toList();
    final points = await _h.getHealthDataFromTypes(types: types, startTime: from, endTime: to);
    final sleep = <SleepSegment>[];
    final spo2 = <SpO2Sample>[];
    for (final p in _h.removeDuplicates(points)) {
      if (p.type == HealthDataType.BLOOD_OXYGEN) {
        final v = p.value;
        if (v is NumericHealthValue) spo2.add(SpO2Sample(p.dateFrom.toLocal(), v.numericValue.toDouble()));
        continue;
      }
      final stage = _stage(p.type);
      if (stage != null) sleep.add(SleepSegment(p.dateFrom.toLocal(), p.dateTo.toLocal(), stage));
    }
    return StoreReadings(const [], sleep, spo2);
  }

  SleepStage? _stage(HealthDataType t) => switch (t) {
        HealthDataType.SLEEP_SESSION => SleepStage.session,
        HealthDataType.SLEEP_ASLEEP => SleepStage.asleep,
        HealthDataType.SLEEP_LIGHT => SleepStage.light,
        HealthDataType.SLEEP_DEEP => SleepStage.deep,
        HealthDataType.SLEEP_REM => SleepStage.rem,
        HealthDataType.SLEEP_AWAKE => SleepStage.awake,
        _ => null,
      };

  @override
  Future<int?> steps(DateTime from, DateTime to) async {
    await _configure();
    // Health Connect and Apple Health both de-duplicate steps from phone and watch here
    return _h.getTotalStepsInInterval(from, to);
  }
}
