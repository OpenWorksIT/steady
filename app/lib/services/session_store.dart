// SPDX-License-Identifier: AGPL-3.0-or-later
// Where the session is kept. On phones: the keychain or keystore. In a browser, a staff
// session is kept in that tab's session storage, so closing it ends the session and a shared
// computer doesn't stay signed in (the browser's linked-device key stays, in secure storage);
// a patient's stays across visits.
export 'session_store_io.dart' if (dart.library.js_interop) 'session_store_web.dart';
