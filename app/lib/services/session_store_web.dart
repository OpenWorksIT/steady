// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:web/web.dart' as web;

// In a browser, a staff session lives in that tab's session storage: closing the tab ends it,
// so a shared computer at the practice doesn't stay signed in to everyone's patients. A
// patient's session stays across visits, as before (their own phone, and the web app is how an
// iPhone without the app uses Steady).

bool _keepAcrossVisits(String value) {
  try {
    final m = jsonDecode(value);
    final model = m is Map ? m['model'] : null;
    return model is Map && model['role'] == 'patient';
  } catch (_) {
    return false;
  }
}

Future<String?> readSession(FlutterSecureStorage storage, String key) async {
  final tab = web.window.sessionStorage.getItem(key);
  if (tab != null) return tab;
  String? kept;
  try {
    kept = await storage.read(key: key);
  } catch (_) {
    kept = null;
  }
  if (kept == null || _keepAcrossVisits(kept)) return kept;
  // a staff session an older version kept in long-term storage: this tab only from now on
  try {
    await storage.delete(key: key);
  } catch (_) {/* stays until the next sign-out */}
  web.window.sessionStorage.setItem(key, kept);
  return kept;
}

Future<void> writeSession(FlutterSecureStorage storage, String key, String value) async {
  if (_keepAcrossVisits(value)) {
    web.window.sessionStorage.removeItem(key);
    await storage.write(key: key, value: value);
    return;
  }
  web.window.sessionStorage.setItem(key, value);
  try {
    await storage.delete(key: key);
  } catch (_) {/* nothing kept there */}
}

Future<void> deleteSession(FlutterSecureStorage storage, String key) async {
  web.window.sessionStorage.removeItem(key);
  try {
    await storage.delete(key: key);
  } catch (_) {/* nothing kept there */}
}
