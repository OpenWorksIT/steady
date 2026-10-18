// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Scanning an invite QR code. The scanner (ZXing, no Google services) only exists in the
// phone app; the web app gets the code from its own address instead (?invite=...).
export 'invite_scan_stub.dart' if (dart.library.io) 'invite_scan_native.dart';
