// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Community tab's rules, kept apart so they can be tested without a browser or a phone.
import 'package:flutter/foundation.dart';

/// Whether the Community tab can work here. In a browser the community sits in a frame, which
/// keeps its sign-in only when this page and the community are one site (vr.steadyapp.co.za and
/// community.steadyapp.co.za); the phone app has its own web view and always can.
bool communityTabHere(String forum) => !kIsWeb || sameSite(Uri.base.host, forum);

/// Whether OpenWorks support gets the Community tab: only on OpenWorks' own server (the server
/// says so), never on a practice's, where the server and the sign-in bridge would refuse it.
bool supportCommunityTab(String forum, bool ownServer) => forum.isNotEmpty && ownServer && communityTabHere(forum);

/// The page's host and the community share its parent domain.
bool sameSite(String pageHost, String forum) {
  final host = Uri.tryParse(forum)?.host ?? '';
  final dot = host.indexOf('.');
  if (dot < 0) return false;
  final parent = host.substring(dot + 1);
  return parent.contains('.') && (pageHost == parent || pageHost.endsWith('.$parent'));
}

/// The tab keeps the community and its sign-in; any other address opens in the browser.
bool staysInTab(Uri address, String forum, String bridge) {
  if (address.scheme != 'https') return false;
  return {Uri.parse(forum).host, Uri.parse(bridge).host}.contains(address.host);
}

/// What a community page told the tab (community/signin/web/app.js): "sign-in" (open it again for
/// whoever is signed in to Steady) or "signed-out". Anything else is ignored.
String? tabMessage(Object? raw) {
  if (raw is! String) return null;
  const prefix = 'steady-community:';
  final m = raw.startsWith(prefix) ? raw.substring(prefix.length) : raw;
  return m == 'sign-in' || m == 'signed-out' ? m : null;
}
