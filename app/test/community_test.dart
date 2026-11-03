// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:steady/services/api.dart';
import 'package:steady/ui/community/community_rules.dart';

void main() {
  test('the community opens only at an https address', () {
    expect(isForumAddress('https://signin.steadyapp.co.za/enter?p=%7B%7D&s=ab'), isTrue);
    expect(isForumAddress('http://signin.steadyapp.co.za/enter'), isFalse);
    expect(isForumAddress('javascript:alert(1)'), isFalse);
    expect(isForumAddress('https://user:pw@signin.steadyapp.co.za/'), isFalse);
    expect(isForumAddress(''), isFalse);
  });

  test('inside the tab: the community and its sign-in, other sites go to the browser', () {
    const forum = 'https://community.steadyapp.co.za';
    const bridge = 'https://signin.steadyapp.co.za/enter?p=x&s=y';
    expect(staysInTab(Uri.parse('https://community.steadyapp.co.za/t/welcome/5'), forum, bridge), isTrue);
    expect(staysInTab(Uri.parse('https://signin.steadyapp.co.za/discourse?sso=a&sig=b'), forum, bridge), isTrue);
    expect(staysInTab(Uri.parse('https://example.org/paper.pdf'), forum, bridge), isFalse);
    expect(staysInTab(Uri.parse('http://community.steadyapp.co.za/'), forum, bridge), isFalse);
    expect(staysInTab(Uri.parse('https://community.steadyapp.co.za.evil.example/'), forum, bridge), isFalse);
  });

  test('what the community page tells the tab', () {
    expect(tabMessage('steady-community:sign-in'), 'sign-in');
    expect(tabMessage('sign-in'), 'sign-in');
    expect(tabMessage('steady-community:signed-out'), 'signed-out');
    expect(tabMessage('something else'), isNull);
    expect(tabMessage(null), isNull);
  });

  test('in a browser, the tab only where the community shares the site', () {
    const forum = 'https://community.steadyapp.co.za';
    expect(sameSite('vr.steadyapp.co.za', forum), isTrue);
    expect(sameSite('test.steadyapp.co.za', forum), isTrue);
    expect(sameSite('steady.openworks.co.za', forum), isFalse);
    expect(sameSite('steadyapp.co.za.evil.example', forum), isFalse);
    expect(sameSite('vr.steadyapp.co.za', 'https://localhost'), isFalse);
  });
}
