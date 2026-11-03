// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:steady/export/agreement_pdf.dart';
import 'package:steady/services/operator_agreement.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // the very text the server serves
  final text = File('../server/pb_hooks/content/operator-agreement.md').readAsStringSync();

  test('the agreement reads as a title, numbered sections, the Schedule, paragraphs and lists', () {
    final blocks = agreementBlocks(text);
    expect(blocks.first.kind, AgreementBlockKind.title);
    expect(blocks.first.text, 'Operator agreement for Steady');
    final headings = blocks.where((b) => b.kind == AgreementBlockKind.heading).map((b) => b.text).toList();
    expect(headings.first, '1. The parties');
    expect(headings.last, "Schedule: the Practice's details");
    expect(headings.where((h) => RegExp(r'^\d+\. ').hasMatch(h)).length, 21);
    expect(blocks.where((b) => b.kind == AgreementBlockKind.item), isNotEmpty);
    // nothing of the markup is left in what's shown
    for (final b in blocks) {
      expect(b.text.startsWith('#') || b.text.startsWith('- ') || b.text.isEmpty, isFalse, reason: b.text);
    }
    // a clause's lines stay one paragraph
    expect(blocks.any((b) => b.kind == AgreementBlockKind.paragraph && b.text.startsWith('9.1 OpenWorks notifies the Practice immediately')), isTrue);
  });

  test('the Information Officer: the master clinician unless the practice names someone else', () {
    const master = AgreementDetails(practiceName: 'VR Clinical Psychology', registration: 'PR 1', address: 'Gqeberha', email: 'a@b.co', phone: '041');
    expect(master.toSignJson()['informationOfficer'], {'master': true});
    const other = AgreementDetails(officerIsMaster: false, officerName: 'Ms Officer', officerEmail: 'io@b.co', officerPhone: '041 1');
    expect(other.toSignJson()['informationOfficer'], {'master': false, 'name': 'Ms Officer', 'email': 'io@b.co', 'phone': '041 1'});
  });

  final signed = SignedAgreement.fromJson({
    'id': 'r1234567890abcd',
    'version': '1.0',
    'sha256': 'ab' * 32,
    'text': text,
    'signerName': 'Dr Démo',
    'signerEmail': 'demo@example.org',
    'signature': 'Kempie van Rooyen',
    'signedAt': DateTime.utc(2026, 11, 3, 8, 30).millisecondsSinceEpoch,
    'ip': '196.0.0.1',
    'userAgent': 'Dart/3.10 (dart:io)',
    'fields': {
      'practice': {'name': 'VR Clinical Psychology', 'registration': 'PR 0123456', 'address': '26 9th Avenue, Walmer, Gqeberha', 'email': 'info@example.org', 'phone': '041 000 0000'},
      'informationOfficer': {'master': true, 'name': 'Dr Démo', 'email': 'demo@example.org', 'phone': ''},
    },
  });

  test('a signed copy and its Schedule', () {
    expect(signed.details.practiceName, 'VR Clinical Psychology');
    expect(signed.details.officerIsMaster, isTrue);
    final rows = {for (final r in scheduleRows(signed)) r.$1: r.$2};
    expect(rows['Information Officer'], 'Dr Démo, the master clinician (demo@example.org)');
    expect(rows['Contact'], 'info@example.org, 041 000 0000');
    expect(rows['Signed by'], contains('Kempie van Rooyen'));
    expect(rows['Signed on'], contains('November 2026'));
    final waiting = OperatorAgreement.fromJson({'version': '1.0', 'sha256': 'x', 'text': text, 'signed': false, 'canSign': true});
    expect(waiting.waitingForSignature, isTrue);
    expect(OperatorAgreement.fromJson({'version': '1.0', 'text': text, 'signed': false, 'canSign': false}).waitingForSignature, isFalse,
        reason: 'only the master clinician is asked');
    expect(OperatorAgreement.fromJson({'version': '1.0', 'text': text, 'signed': true, 'canSign': true}).waitingForSignature, isFalse);
  });

  test('the signed copy as a PDF', () async {
    final bytes = await buildAgreementPdf(signed);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(bytes.length, greaterThan(5000));
  });
}
