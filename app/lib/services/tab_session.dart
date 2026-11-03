// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Practice staff in a web browser: the session belongs to the tab. It is kept in the tab's own
// storage (session_store_web.dart), so closing the tab ends it in the browser, and the server
// gives it short tokens (an hour; server/pb_hooks/lib/sessions.js), so a copy taken from a
// closed tab soon stops working. While the tab is open this renews the token in the background,
// long before it runs out, so nobody is signed out halfway through a session: there is no idle
// sign-out. Nothing is done when the tab closes: a "beforeunload" or "pagehide" sign-out would
// also fire on every reload, which keeps the session.
//
// A computer that sleeps for longer than the token has left (40 to 60 minutes) comes back to
// the sign-in screen: the server no longer accepts the token.
//
// Phones and patients don't use this; their sessions are as before.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:pocketbase/pocketbase.dart';

import '../app_state.dart';

/// When a session token runs out (its "exp"), or null if it doesn't say.
DateTime? tokenExpiry(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  try {
    final claims = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    final exp = claims is Map ? claims['exp'] : null;
    return exp is num ? DateTime.fromMillisecondsSinceEpoch((exp * 1000).round(), isUtc: true) : null;
  } catch (_) {
    return null;
  }
}

/// How long to wait before renewing a token that runs out at [expires]: a third of the time it
/// has left, so two thirds remain for a sleeping computer or a lost connection. Never less than
/// a few seconds; nothing at all when it has already run out.
Duration renewAfter(DateTime expires, DateTime now) {
  final left = expires.difference(now);
  if (left <= Duration.zero) return Duration.zero;
  final wait = left ~/ 3;
  const least = Duration(seconds: 5);
  return wait < least ? (left < least ? Duration.zero : least) : wait;
}

class TabSession {
  TabSession(this.state, {this.navigatorKey});
  final AppState state;

  /// The app's navigator: when the session ends, every screen opened on top closes.
  final GlobalKey<NavigatorState>? navigatorKey;
  Timer? _timer;
  StreamSubscription<Object?>? _changes;
  AppLifecycleListener? _life;
  // when the current token is to be renewed: set once per token, so looking again (a tab coming
  // back to the front) never puts it off
  String _forToken = '';
  DateTime? _renewAt;

  bool get _staffInBrowser => kIsWeb && state.api.signedIn && state.api.isStaff;

  void start() {
    if (!kIsWeb) return;
    // each new token (signing in, a renewal) sets the next renewal
    _changes ??= state.api.pb.authStore.onChange.listen((_) => _schedule());
    // a tab coming back from the background, or a computer waking up: look again
    _life ??= AppLifecycleListener(onResume: _schedule);
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    final api = state.api;
    if (!api.isStaff) return;
    final token = api.pb.authStore.token;
    final expires = tokenExpiry(token);
    if (expires == null) return;
    final now = DateTime.now();
    if (token != _forToken || _renewAt == null) {
      _forToken = token;
      _renewAt = now.add(renewAfter(expires, now));
    }
    final wait = _renewAt!.difference(now);
    _timer = Timer(wait.isNegative ? Duration.zero : wait, _renew);
  }

  Future<void> _renew() async {
    _timer = null;
    final api = state.api;
    if (!api.isStaff) return;
    // the time ran out while the computer slept: the server won't take the token any more
    if (!api.pb.authStore.isValid) {
      _ended();
      return;
    }
    if (!_staffInBrowser) return;
    try {
      await api.refresh(); // the new token sets the next renewal
    } on ClientException catch (e) {
      // the server ended the session: signed out everywhere, the account stopped, or run out
      if (e.statusCode == 401 || e.statusCode == 403 || e.statusCode == 404) {
        _ended();
      } else {
        _retry();
      }
    } catch (_) {
      _retry();
    }
  }

  /// No connection, or the server is busy: try again in a minute.
  void _retry() {
    _renewAt = DateTime.now().add(const Duration(minutes: 1));
    _schedule();
  }

  /// Back to the sign-in screen, with nothing left open on top of it.
  void _ended() {
    if (state.api.pb.authStore.token.isEmpty) return;
    navigatorKey?.currentState?.popUntil((r) => r.isFirst);
    state.api.signOut();
    state.changed();
  }
}
