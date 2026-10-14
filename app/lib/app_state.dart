// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/widgets.dart';

import 'models.dart';
import 'services/api.dart';
import 'services/push.dart';

/// App-wide state: the API client, server configuration and who is signed in.
class AppState extends ChangeNotifier {
  final Api api;
  AppConfig config = AppConfig.fallback();
  bool pushEnabled = false;
  AppState(this.api);

  bool get signedIn => api.signedIn;
  bool get isClinician => api.role == 'clinician';
  bool get isPatient => api.role == 'patient';

  Future<void> start() async {
    try {
      config = await api.config();
    } catch (_) {/* keep fallback; crisis numbers are built in */}
    if (api.signedIn) {
      try {
        await api.refresh();
      } catch (_) {
        // expired or deactivated
        api.signOut();
      }
    }
    notifyListeners();
    if (api.signedIn) unawaited(enablePush());
  }

  Future<void> enablePush() async {
    try {
      pushEnabled = await PushService.instance.enable(vapidPublicKey: config.vapidPublicKey);
    } catch (_) {
      pushEnabled = false;
    }
    notifyListeners();
  }

  Future<void> signedInNow() async {
    notifyListeners();
    unawaited(enablePush());
  }

  Future<void> signOut() async {
    await PushService.instance.disable();
    api.signOut();
    notifyListeners();
  }
}

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({required AppState state, required super.child, super.key}) : super(notifier: state);
  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
  static Api api(BuildContext context) => of(context).api;
}
