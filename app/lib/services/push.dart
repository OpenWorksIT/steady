// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Push notifications. Every one is titled "Steady" and says "New notification", nothing else:
// no names, no answers, not even what kind of thing is new. The app loads that over its own
// connection when it's opened.
//   iOS     - Apple Push Notification service, through packages/steady_apns. No Firebase.
//   Android - Firebase Cloud Messaging, through packages/steady_fcm (Android only, so Firebase
//             never goes into the iPhone or web app). It needs the Firebase settings below,
//             which CI passes in from repository variables; a build without them has no
//             notifications on Android, and says so in Settings.
// The web app has none.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'api.dart';

/// OpenWorks IT's Firebase project, which Android notifications come through. These identify
/// the app to Firebase and are in every copy of it; they aren't secrets. Set with
/// --dart-define=FIREBASE_API_KEY=... (docs/APP.md, "Notifications"); empty in forks and local builds.
const _firebaseApiKey = String.fromEnvironment('FIREBASE_API_KEY');
const _firebaseAppId = String.fromEnvironment('FIREBASE_APP_ID');
const _firebaseSenderId = String.fromEnvironment('FIREBASE_SENDER_ID');
const _firebaseProjectId = String.fromEnvironment('FIREBASE_PROJECT_ID');

/// Whether this copy of the app was built with the Firebase settings Android notifications need.
const kAndroidPushBuiltIn =
    _firebaseApiKey != '' && _firebaseAppId != '' && _firebaseSenderId != '' && _firebaseProjectId != '';

const _firebase = {
  'apiKey': _firebaseApiKey,
  'appId': _firebaseAppId,
  'senderId': _firebaseSenderId,
  'projectId': _firebaseProjectId,
};

class PushService {
  PushService._();
  static final instance = PushService._();

  static const _apns = MethodChannel('za.co.openworks.steady/push');
  static const _fcm = MethodChannel('za.co.openworks.steady/fcm');
  final _taps = StreamController<String>.broadcast();
  Api? _api;
  bool _initialised = false;

  /// Emits when a notification is tapped while the app is running, so the screen can refresh.
  /// The value is always empty: a notification carries nothing to tell it apart.
  Stream<String> get taps => _taps.stream;

  /// Call from main() before runApp, so the phone's answers (a token, a tap) have somewhere to go.
  Future<void> init(Api api) async {
    _api = api;
    if (_initialised) return;
    _initialised = true;
    if (kIsWeb) return;
    if (_isAndroid) {
      _fcm.setMethodCallHandler((call) async {
        if (call.method == 'onTap') _taps.add('');
      });
    } else if (_isIOS) {
      _apns.setMethodCallHandler((call) async {
        switch (call.method) {
          case 'onToken':
            final args = Map<String, dynamic>.from(call.arguments as Map);
            await _api?.registerDevice(
              platform: 'ios',
              provider: 'apns',
              token: '${args['token']}',
              sandbox: args['sandbox'] == true,
            );
          case 'onTap':
            _taps.add('');
        }
      });
    }
  }

  /// Asks for permission and registers this phone with the server. Call after sign-in, and on
  /// each start (a phone's token can change). False when notifications are off: the phone
  /// doesn't allow them, or (Android) this copy was built without Firebase.
  Future<bool> enable() async {
    if (kIsWeb) return false;
    if (_isIOS) {
      final ok = await _apns.invokeMethod<bool>('register');
      return ok ?? false;
    }
    if (_isAndroid) {
      if (!kAndroidPushBuiltIn) return false;
      final token = await _fcm.invokeMethod<String>('register', _firebase);
      if (token == null || token.isEmpty) return false;
      await _api?.registerDevice(platform: 'android', provider: 'fcm', token: token);
      return true;
    }
    return false;
  }

  /// Signing out or changing server. On Android the phone's Firebase token is deleted, so whoever
  /// signs in next gets a new one. (The server forgets this phone's registration: Api.forgetThisDevice.)
  Future<void> disable() async {
    if (kIsWeb || !_isAndroid || !kAndroidPushBuiltIn) return;
    await _fcm.invokeMethod<void>('unregister', _firebase);
  }
}

/// What Settings says about notifications on this phone.
String pushStatusText({required bool on, bool web = kIsWeb, bool? android, bool builtIn = kAndroidPushBuiltIn}) {
  final isAndroid = android ?? _isAndroid;
  if (web) {
    return 'The web version can\'t send notifications. New items appear here while the page is open; install the app for alerts.';
  }
  if (isAndroid && !builtIn) {
    return 'Off. This copy of Steady was built without notifications. New items show when you open the app.';
  }
  if (on) {
    final via = isAndroid ? 'Google' : 'Apple';
    return 'On. Notifications come through $via and only ever say "New notification". Open Steady to see what\'s new.';
  }
  return 'Off. Allow notifications for Steady in your phone\'s settings.';
}

bool get _isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
bool get _isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
