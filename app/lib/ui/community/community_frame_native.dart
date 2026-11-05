// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The phone app: the community in a web view of its own (its cookies stay in the app, apart from
// the phone's browser). It keeps to the community and its sign-in; any other link opens in the
// browser. The community refuses to open as a page of its own (community/community.caddy): the
// steady_app cookie, set only here, says it's inside the app. The community's pages tell the tab
// what they mean through the SteadyCommunity channel (community/signin/web/app.js).
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'community_rules.dart';

/// Signing out of Steady: the community's cookies in the app go too, so the next person on this
/// phone starts afresh.
Future<void> forgetCommunity() async {
  try {
    await WebViewCookieManager().clearCookies();
  } catch (_) {/* no web view on this device yet */}
}

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
  late final WebViewController _web;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('SteadyCommunity', onMessageReceived: (m) {
        final msg = tabMessage(m.message);
        if (msg != null && mounted) widget.onMessage(msg);
      })
      ..setNavigationDelegate(NavigationDelegate(onNavigationRequest: (r) {
        final u = Uri.tryParse(r.url);
        if (!r.isMainFrame) return NavigationDecision.navigate;
        if (u != null && staysInTab(u, widget.forum, widget.start)) return NavigationDecision.navigate;
        if (u != null && (u.scheme == 'https' || u.scheme == 'mailto')) {
          launchUrl(u, mode: LaunchMode.externalApplication).catchError((_) => false);
        }
        return NavigationDecision.prevent;
      }));
    WebViewCookieManager()
        .setCookie(WebViewCookie(name: 'steady_app', value: '1', domain: Uri.parse(widget.forum).host))
        .whenComplete(() => _web.loadRequest(Uri.parse(widget.start)));
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _web);
}
