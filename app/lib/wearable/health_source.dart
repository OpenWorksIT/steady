// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Access to the phone's health store. The real implementation (Health Connect on Android,
// Apple Health on iOS) is only compiled for phones; the web build gets a stub.
import 'summary.dart';

export 'health_source_stub.dart' if (dart.library.io) 'health_source_native.dart';

enum StoreStatus { ready, notInstalled, updateRequired, unsupported }

/// Readings for a period, as read from the health store.
class StoreReadings {
  final List<HrSample> hr;
  final List<SleepSegment> sleep;
  final List<SpO2Sample> spo2;
  const StoreReadings(this.hr, this.sleep, this.spo2);
}

abstract class HealthStore {
  /// Shown in the app, e.g. "Health Connect" or "Apple Health".
  String get name;
  String get platform; // android | ios
  Future<StoreStatus> status();
  Future<void> openInstall();

  /// Asks the person for read access. Returns false if they declined.
  Future<bool> requestAccess();

  /// Whether Steady may still read: true or false on Android (Health Connect can lose its
  /// permissions, e.g. after an update), null where the phone won't say (Apple Health never
  /// reveals whether read access was granted).
  Future<bool?> hasAccess();
  /// Heart rate only; it can be dense, so read it in short spans.
  Future<List<HrSample>> heartRate(DateTime from, DateTime to);

  /// Sleep and blood oxygen; small enough to read weeks at a time.
  Future<StoreReadings> sleepAndOxygen(DateTime from, DateTime to);
  Future<int?> steps(DateTime from, DateTime to);
}
