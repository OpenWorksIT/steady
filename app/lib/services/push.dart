// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Push notifications without Firebase:
//   iOS     - Apple Push Notification service, through a small platform channel in
//             ios/Runner/AppDelegate.swift (see app/platform/ios).
//   Android - UnifiedPush. The patient or clinician picks a distributor app (for example
//             ntfy). Messages arrive Web Push encrypted and are shown with a local notification.
// Payloads never contain patient details; tapping opens the app, which loads the detail.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:unifiedpush/unifiedpush.dart';

import 'api.dart';

class PushService {
  PushService._();
  static final instance = PushService._();

  static const _channel = MethodChannel('za.co.openworks.steady/push');
  final _local = FlutterLocalNotificationsPlugin();
  final _taps = StreamController<String>.broadcast();
  Api? _api;
  String _vapid = '';
  bool _initialised = false;

  /// Emits the "kind" of a notification the user tapped, so the app can refresh.
  Stream<String> get taps => _taps.stream;

  /// Call from main() before runApp. UnifiedPush starts the app's main() in the
  /// background to deliver messages, so the receiver must be set up here.
  Future<void> init(Api api) async {
    _api = api;
    if (_initialised) return;
    _initialised = true;
    if (kIsWeb) return;
    if (_isAndroid) {
      await _local.initialize(
        settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
        onDidReceiveNotificationResponse: (r) => _taps.add(r.payload ?? ''),
      );
      await UnifiedPush.initialize(
        onNewEndpoint: (endpoint, instance) => _onNewEndpoint(endpoint),
        onUnregistered: (instance) {},
        onRegistrationFailed: (reason, instance) {},
        onMessage: (message, instance) => _onMessage(message),
      );
    } else if (_isIOS) {
      _channel.setMethodCallHandler((call) async {
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
            _taps.add('${call.arguments ?? ''}');
        }
      });
    }
  }

  /// Ask for permission and register this device. Call after sign-in.
  /// Returns false on Android when no UnifiedPush distributor is installed.
  Future<bool> enable({String vapidPublicKey = ''}) async {
    _vapid = vapidPublicKey;
    if (kIsWeb) return false;
    if (_isIOS) {
      final ok = await _channel.invokeMethod<bool>('register');
      return ok ?? false;
    }
    if (_isAndroid) {
      await _local
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      final hasDistributor = await UnifiedPush.tryUseCurrentOrDefaultDistributor();
      if (!hasDistributor) return false;
      await UnifiedPush.register(vapid: _vapid.isEmpty ? null : _vapid);
      return true;
    }
    return false;
  }

  /// Installed UnifiedPush distributors, for the settings screen.
  Future<List<String>> distributors() async =>
      (!kIsWeb && _isAndroid) ? await UnifiedPush.getDistributors() : <String>[];

  Future<void> useDistributor(String id) async {
    await UnifiedPush.saveDistributor(id);
    await UnifiedPush.register(vapid: _vapid.isEmpty ? null : _vapid);
  }

  Future<void> disable() async {
    if (!kIsWeb && _isAndroid) await UnifiedPush.unregister();
  }

  Future<void> _onNewEndpoint(PushEndpoint endpoint) async {
    final keys = endpoint.pubKeySet;
    if (keys == null) return; // the relay only sends encrypted messages
    final token = jsonEncode({'endpoint': endpoint.url, 'p256dh': keys.pubKey, 'auth': keys.auth});
    await _api?.registerDevice(platform: 'android', provider: 'unifiedpush', token: token);
  }

  Future<void> _onMessage(PushMessage message) async {
    var title = 'Steady';
    var body = 'You have a new update.';
    var kind = '';
    if (message.decrypted) {
      try {
        final j = jsonDecode(utf8.decode(message.content));
        if (j is Map) {
          title = '${j['title'] ?? title}';
          body = '${j['body'] ?? body}';
          kind = '${(j['data'] is Map ? j['data']['kind'] : null) ?? ''}';
        }
      } catch (_) {/* show the generic text */}
    }
    await _local.show(
      id: DateTime.now().millisecondsSinceEpoch ~/ 1000 % 100000,
      title: title,
      body: body,
      payload: kind,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'steady_updates',
          'Updates',
          channelDescription: 'New check-ins, results and activities',
          importance: Importance.high,
          priority: Priority.high,
          visibility: NotificationVisibility.private,
        ),
      ),
    );
  }
}

bool get _isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
bool get _isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
