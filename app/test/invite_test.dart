// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:steady/services/api.dart';

void main() {
  test('invite links round-trip', () {
    final link = inviteLink('https://steady.example.co.za/', 'abcd-2345');
    expect(link, 'https://steady.example.co.za/join?invite=ABCD2345');
    final inv = parseInviteLink(link)!;
    expect(inv.server, 'https://steady.example.co.za');
    expect(inv.code, 'ABCD2345');
  });

  test('keeps a port and a path', () {
    final inv = parseInviteLink('https://example.org:8443/steady/?invite=WXYZ-7890')!;
    expect(inv.server, 'https://example.org:8443/steady');
    expect(inv.code, 'WXYZ7890');
  });

  test('older links without /join still work', () {
    final inv = parseInviteLink('https://steady.example.co.za/?invite=ABCD2345')!;
    expect(inv.server, 'https://steady.example.co.za');
  });

  test('rejects things that are not invites', () {
    expect(parseInviteLink('hello'), isNull);
    expect(parseInviteLink('https://example.org/'), isNull);
    expect(parseInviteLink('https://example.org/?invite=ABC'), isNull);
    expect(parseInviteLink('ftp://example.org/?invite=ABCD2345'), isNull);
    expect(parseInviteLink('javascript:alert(1)//?invite=ABCD2345'), isNull);
  });
}
