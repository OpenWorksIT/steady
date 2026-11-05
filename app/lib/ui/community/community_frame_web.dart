// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The web app: the community in a frame. Steady's own pages allow frames from the community and
// its sign-in only (deploy/Caddyfile, frame-src), and the community lets only Steady's pages
// frame it (community/community.caddy). The community's pages tell the tab what they mean with
// a message (community/signin/web/app.js), taken only from the sign-in's own address.
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'community_rules.dart';

/// Signing out of Steady: nothing to do here. The forum's own session in this browser can only be
/// used inside Steady's Community tab, which signs in again as whoever is in Steady.
Future<void> forgetCommunity() async {}

class CommunityFrame extends StatefulWidget {
  /// The sign-in's address with Steady's note (Api.communitySignIn).
  final String start;

  /// The community's own address.
  final String forum;
  final void Function(String message) onMessage;
  const CommunityFrame({required this.start, required this.forum, required this.onMessage, super.key});
  @override
  State<CommunityFrame> createState() => _CommunityFrameState();
}

class _CommunityFrameState extends State<CommunityFrame> {
  static int _made = 0;
  late final String _viewType = 'steady-community-${_made++}';
  JSFunction? _listener;

  @override
  void initState() {
    super.initState();
    final start = widget.start;
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final frame = web.HTMLIFrameElement()
        ..src = start
        ..title = 'Steady community'
        ..allow = 'clipboard-write'
        ..referrerPolicy = 'no-referrer';
      frame.style
        ..border = 'none'
        ..width = '100%'
        ..height = '100%';
      return frame;
    });
    final signIn = Uri.parse(start).origin;
    _listener = ((web.MessageEvent e) {
      if (e.origin != signIn) return;
      final m = tabMessage(e.data.dartify());
      if (m != null && mounted) widget.onMessage(m);
    }).toJS;
    web.window.addEventListener('message', _listener);
  }

  @override
  void dispose() {
    final l = _listener;
    if (l != null) web.window.removeEventListener('message', l);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(viewType: _viewType);
}
