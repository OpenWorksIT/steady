// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A short trail of what the person just did, sent with bug reports so OpenWorks can retrace the
// steps (the same idea as Sorted's). It keeps the last 60 steps: screens opened, taps (the screen
// and where on it), server calls (method, path with ids removed, result and time) and errors.
// Never what was typed, and never names: record ids are replaced and query strings dropped.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

class TrailEntry {
  final int t; // ms since epoch
  final String kind; // nav, tap, api, error
  final String detail;
  const TrailEntry(this.t, this.kind, this.detail);
  Map<String, dynamic> toJson() => {'t': t, 'kind': kind, 'detail': detail};
}

class Trail {
  static const max = 60;
  static final List<TrailEntry> _entries = [];

  /// The screen on top right now (for taps and reports).
  static String screen = 'Start';

  static void record(String kind, String detail) {
    _entries.add(TrailEntry(DateTime.now().millisecondsSinceEpoch, kind, detail.length > 300 ? detail.substring(0, 300) : detail));
    if (_entries.length > max) _entries.removeRange(0, _entries.length - max);
  }

  static List<Map<String, dynamic>> get entries => _entries.map((e) => e.toJson()).toList();

  static final _id = RegExp(r'/[a-z0-9]{15}(?=/|$)');

  /// A path's shape without whose it is: "/api/steady/patients/:id/radr".
  static String scrub(String path) => path.replaceAll(_id, '/:id');
}

/// The name of a route's screen: its settings name, or the first "...Screen" widget in it.
String screenName(Route<dynamic>? route) {
  if (route == null) return 'Start';
  final n = route.settings.name;
  if (n != null && n.isNotEmpty && n != '/') return n;
  if (route is ModalRoute) {
    final ctx = route.subtreeContext;
    if (ctx is Element) {
      String? screen, other;
      final named = RegExp(r'(Screen)$'), alt = RegExp(r'(Shell|Sheet|Flow|Home|Dialog|Tab)$');
      void visit(Element e, int depth) {
        if (screen != null || depth > 80) return;
        final t = e.widget.runtimeType.toString();
        if (named.hasMatch(t)) {
          screen = t;
          return;
        }
        if (other == null && alt.hasMatch(t)) other = t;
        e.visitChildElements((c) => visit(c, depth + 1));
      }

      ctx.visitChildElements((c) => visit(c, 0));
      if (screen != null) return screen!;
      if (other != null) return other!;
    }
  }
  return route is PopupRoute ? 'a popup' : 'a screen';
}

/// Records screens opened and closed.
class TrailObserver extends NavigatorObserver {
  void _note(String verb, Route<dynamic>? route) {
    // the route's widgets exist after the next frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final name = screenName(route);
      Trail.screen = name;
      Trail.record('nav', '$verb $name');
    });
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _note('opened', route);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _note('back to', previousRoute);
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) => _note('opened', newRoute);
}

/// Records every server call the app makes: method, path shape, result and time taken.
class TrailClient extends http.BaseClient {
  final http.Client _inner;
  TrailClient(this._inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final sw = Stopwatch()..start();
    final what = '${request.method} ${Trail.scrub(request.url.path)}';
    try {
      final res = await _inner.send(request);
      Trail.record('api', '$what -> ${res.statusCode} (${sw.elapsedMilliseconds} ms)');
      return res;
    } catch (e) {
      Trail.record('api', '$what failed after ${sw.elapsedMilliseconds} ms (${e.runtimeType})');
      rethrow;
    }
  }

  @override
  void close() => _inner.close();
}

/// Records taps (not scrolls): which screen, and where on it (as a share of the width and height).
class TrailTaps extends StatefulWidget {
  final Widget child;
  const TrailTaps({required this.child, super.key});
  @override
  State<TrailTaps> createState() => _TrailTapsState();
}

class _TrailTapsState extends State<TrailTaps> {
  final _down = <int, Offset>{};

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) => _down[e.pointer] = e.position,
        onPointerCancel: (e) => _down.remove(e.pointer),
        onPointerUp: (e) {
          final start = _down.remove(e.pointer);
          if (start == null || (e.position - start).distance > 18) return; // a scroll or a drag
          final size = MediaQuery.sizeOf(context);
          if (size.width <= 0 || size.height <= 0) return;
          final x = (e.position.dx / size.width * 100).round(), y = (e.position.dy / size.height * 100).round();
          Trail.record('tap', '${Trail.screen} at $x% across, $y% down');
        },
        child: widget.child,
      );
}

/// Errors the app hit, alongside Flutter's own handling.
void startTrailErrorHooks() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    Trail.record('error', details.exceptionAsString());
    previous?.call(details);
  };
  final dispatcher = WidgetsBinding.instance.platformDispatcher;
  final previousAsync = dispatcher.onError;
  dispatcher.onError = (error, stack) {
    Trail.record('error', '$error');
    return previousAsync?.call(error, stack) ?? false;
  };
}
