// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:pocketbase/pocketbase.dart' show ClientException;

import 'build_info.dart';
import 'content/privacy_notice.dart';
import 'models.dart';
import 'services/api.dart';
import 'services/push.dart';

/// App-wide state: the API client, server configuration and who is signed in.
class AppState extends ChangeNotifier {
  final Api api;
  AppConfig config = AppConfig.fallback();
  bool pushEnabled = false;
  bool privacyAcknowledged = false;

  /// An invite code the app was opened with, waiting for the join screen.
  String? pendingInvite;
  String _privacyAckAt = '';
  final _storage = kSecureStorage;
  AppState(this.api);

  static const _privacyKey = 'steady.privacy';

  /// Reads what this phone has already acknowledged. Call before the first frame.
  Future<void> loadLocal() async {
    // the web app opened from an invite QR code: https://<server>/?invite=<code>
    if (kIsWeb) {
      final code = Uri.base.queryParameters['invite'];
      if (code != null && code.trim().isNotEmpty) pendingInvite = code.trim();
    }
    try {
      final v = await _storage.read(key: _privacyKey);
      if (v != null && v.startsWith('$privacyNoticeVersion|')) {
        privacyAcknowledged = true;
        _privacyAckAt = v.substring(privacyNoticeVersion.length + 1);
      }
    } catch (_) {}
  }

  Future<void> acknowledgePrivacy() async {
    _privacyAckAt = DateTime.now().toIso8601String();
    privacyAcknowledged = true;
    try {
      await _storage.write(key: _privacyKey, value: '$privacyNoticeVersion|$_privacyAckAt');
    } catch (_) {}
    notifyListeners();
    unawaited(_recordPrivacyOnServer());
  }

  /// Copies this phone's acknowledgement to the account, once per notice version.
  Future<void> _recordPrivacyOnServer() async {
    if (!privacyAcknowledged || !api.signedIn || api.privacyNoticeVersion == privacyNoticeVersion) return;
    try {
      await api.setConsent('privacy', privacyNoticeVersion);
    } catch (_) {/* tried again next start */}
  }

  bool get signedIn => api.signedIn;
  bool get isClinician => api.role == 'clinician';
  bool get isPatient => api.role == 'patient';
  bool get isAdmin => api.role == 'admin';
  bool get isSupport => api.role == 'support';

  /// Tells the server which version of the app this is (and, for patients, whether the phone
  /// still lets Steady read watch data), so the practice can see who needs to update or
  /// reconnect. Best effort.
  Future<void> reportApp({String health = ''}) async {
    if (!api.signedIn) return;
    final platform = kIsWeb ? 'web' : (defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android');
    try {
      await api.reportApp(build: kAppBuild.isEmpty ? 'dev' : kAppBuild, platform: platform, health: health);
    } catch (_) {}
  }

  /// Staff must set up two-step sign-in before they can see anything (unless the server says off).
  bool get needsTwoStepSetup => api.isStaff && config.twoStep != 'off' && !api.twoStepOn;

  Future<void> start() async {
    if (!api.hasServer) {
      notifyListeners();
      return;
    }
    try {
      config = await api.config();
    } catch (_) {/* keep fallback; crisis numbers are built in */}
    if (api.signedIn) {
      try {
        await api.refresh();
      } on ClientException catch (e) {
        // Signed out only when the server says so (expired, stopped). If it can't be reached,
        // stay signed in: the screens show the problem and work again once it's back.
        if (e.statusCode != 0) api.signOut();
      } catch (_) {/* keep the session */}
    }
    notifyListeners();
    if (api.signedIn) {
      unawaited(enablePush());
      unawaited(_recordPrivacyOnServer());
      unawaited(reportApp());
    }
  }

  Future<void> enablePush() async {
    try {
      pushEnabled = await PushService.instance.enable(vapidPublicKey: config.vapidPublicKey);
    } catch (_) {
      pushEnabled = false;
    }
    notifyListeners();
  }

  /// Switches to another server (test builds). Signs out.
  Future<void> setServer(String url) async {
    await PushService.instance.disable();
    await api.setServer(url);
    try {
      config = await api.config();
    } catch (_) {
      config = AppConfig.fallback();
    }
    notifyListeners();
  }

  /// Something about the signed-in account changed (e.g. consent); redraw.
  void changed() => notifyListeners();

  Future<void> signedInNow() async {
    notifyListeners();
    unawaited(enablePush());
    unawaited(_recordPrivacyOnServer());
    unawaited(reportApp());
  }

  Future<void> signOut() async {
    await api.forgetThisDevice();
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
