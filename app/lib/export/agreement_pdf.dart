// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The signed operator agreement as a PDF: the text exactly as signed, then the Schedule with the
// practice's details, and the record of the signature (when, by whom, the text's fingerprint).
// Built on the device; nothing is sent anywhere else.
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../services/operator_agreement.dart';

const _ink = PdfColor.fromInt(0xFF1F2A33);
const _ink2 = PdfColor.fromInt(0xFF5B6770);
const _line = PdfColor.fromInt(0xFFB9C4CA);

Future<Uint8List> buildAgreementPdf(SignedAgreement s) async {
  final base = pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans.ttf'));
  final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans-Bold.ttf'));
  final practice = s.details.practiceName.isEmpty ? 'the practice' : s.details.practiceName;
  final doc = pw.Document(
    theme: pw.ThemeData.withFont(base: base, bold: bold),
    title: 'Operator agreement, version ${s.version}: $practice and OpenWorks IT',
    author: s.signature,
    creator: 'Steady (OpenWorks IT)',
  );
  final blocks = agreementBlocks(s.text);
  doc.addPage(pw.MultiPage(
    pageTheme: const pw.PageTheme(pageFormat: PdfPageFormat.a4, margin: pw.EdgeInsets.fromLTRB(48, 40, 48, 40)),
    footer: (ctx) => pw.Padding(
      padding: const pw.EdgeInsets.only(top: 10),
      child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text('Operator agreement, version ${s.version} · $practice · signed in Steady',
            style: const pw.TextStyle(fontSize: 7, color: _ink2)),
        pw.Text('${ctx.pageNumber} / ${ctx.pagesCount}', style: const pw.TextStyle(fontSize: 7, color: _ink2)),
      ]),
    ),
    build: (ctx) => [
      for (final b in blocks) _block(b),
      pw.SizedBox(height: 12),
      pw.Container(
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(border: pw.Border.all(color: _line, width: 0.8)),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text('Schedule, as given when signing', style: pw.TextStyle(fontSize: 11.5, fontWeight: pw.FontWeight.bold, color: _ink)),
          pw.SizedBox(height: 6),
          for (final r in scheduleRows(s)) _row(r.$1, r.$2),
        ]),
      ),
      pw.SizedBox(height: 10),
      pw.Text('Record of the signature', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: _ink2)),
      pw.SizedBox(height: 4),
      _row('Version', s.version),
      _row('Text fingerprint (SHA-256)', s.sha256),
      _row('Internet address', s.ip),
      _row('App', s.userAgent),
      _row('Record', s.id),
    ],
  ));
  return doc.save();
}

const _body = pw.TextStyle(fontSize: 9.5, color: _ink, lineSpacing: 1.5);

pw.Widget _block(AgreementBlock b) {
  switch (b.kind) {
    case AgreementBlockKind.title:
      return pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 6),
          child: pw.Text(b.text, style: pw.TextStyle(fontSize: 17, fontWeight: pw.FontWeight.bold, color: _ink)));
    case AgreementBlockKind.heading:
      return pw.Padding(
          padding: const pw.EdgeInsets.only(top: 10, bottom: 4),
          child: pw.Text(b.text, style: pw.TextStyle(fontSize: 11.5, fontWeight: pw.FontWeight.bold, color: _ink)));
    case AgreementBlockKind.item:
      return pw.Padding(
          padding: const pw.EdgeInsets.only(left: 10, bottom: 3),
          child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.SizedBox(width: 10, child: pw.Text('•', style: _body)),
            pw.Expanded(child: pw.Text(b.text, style: _body)),
          ]));
    case AgreementBlockKind.paragraph:
      return pw.Padding(padding: const pw.EdgeInsets.only(bottom: 5), child: pw.Text(b.text, style: _body));
  }
}

pw.Widget _row(String label, String value) => pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 3),
      child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.SizedBox(width: 150, child: pw.Text(label, style: const pw.TextStyle(fontSize: 8.5, color: _ink2))),
        pw.Expanded(child: pw.Text(value.isEmpty ? '-' : value, style: const pw.TextStyle(fontSize: 8.5, color: _ink))),
      ]),
    );
