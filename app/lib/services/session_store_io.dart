// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

Future<String?> readSession(FlutterSecureStorage storage, String key) => storage.read(key: key);

Future<void> writeSession(FlutterSecureStorage storage, String key, String value) => storage.write(key: key, value: value);

Future<void> deleteSession(FlutterSecureStorage storage, String key) => storage.delete(key: key);
