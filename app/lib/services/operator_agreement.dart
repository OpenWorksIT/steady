// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The operator agreement between the practice and OpenWorks IT (POPIA section 21): the master
// clinician signs it in the app (ui/practice/operator_agreement_screen.dart), and the master
// clinician, the practice admin and OpenWorks support can open the signed copy. The server keeps
// every signature and never changes one (server/pb_hooks/steady_operator.pb.js).
import '../models.dart';
import 'api.dart';

/// The practice's details as given when signing (the agreement's Schedule).
class AgreementDetails {
  final String practiceName, registration, address, email, phone;

  /// The master clinician who signs is the Information Officer unless the practice names someone.
  final bool officerIsMaster;
  final String officerName, officerEmail, officerPhone;

  const AgreementDetails({
    this.practiceName = '',
    this.registration = '',
    this.address = '',
    this.email = '',
    this.phone = '',
    this.officerIsMaster = true,
    this.officerName = '',
    this.officerEmail = '',
    this.officerPhone = '',
  });

  /// From the server's stored form: { practice: {...}, informationOfficer: {...} }.
  factory AgreementDetails.fromJson(Map<String, dynamic> j) {
    final p = asMap(j['practice']), o = asMap(j['informationOfficer']);
    return AgreementDetails(
      practiceName: '${p['name'] ?? ''}',
      registration: '${p['registration'] ?? ''}',
      address: '${p['address'] ?? ''}',
      email: '${p['email'] ?? ''}',
      phone: '${p['phone'] ?? ''}',
      officerIsMaster: o['master'] != false,
      officerName: '${o['name'] ?? ''}',
      officerEmail: '${o['email'] ?? ''}',
      officerPhone: '${o['phone'] ?? ''}',
    );
  }

  /// What the sign route takes.
  Map<String, dynamic> toSignJson() => {
        'practiceName': practiceName,
        'registration': registration,
        'address': address,
        'email': email,
        'phone': phone,
        'informationOfficer': officerIsMaster
            ? {'master': true}
            : {'master': false, 'name': officerName, 'email': officerEmail, 'phone': officerPhone},
      };
}

/// The agreement as it stands on the server, and whether this version is signed.
class OperatorAgreement {
  final String version, sha256, text, lastSignedVersion;
  final bool signed, canSign;
  final DateTime? signedAt;

  /// The details last signed (or the practice's name): only for the master clinician.
  final AgreementDetails prefill;

  const OperatorAgreement({
    required this.version,
    required this.sha256,
    required this.text,
    this.signed = false,
    this.canSign = false,
    this.signedAt,
    this.lastSignedVersion = '',
    this.prefill = const AgreementDetails(),
  });

  factory OperatorAgreement.fromJson(Map<String, dynamic> j) => OperatorAgreement(
        version: '${j['version'] ?? ''}',
        sha256: '${j['sha256'] ?? ''}',
        text: '${j['text'] ?? ''}',
        signed: j['signed'] == true,
        canSign: j['canSign'] == true,
        signedAt: fromMs(j['signedAt']),
        lastSignedVersion: '${j['lastSignedVersion'] ?? ''}',
        prefill: AgreementDetails.fromJson(asMap(j['prefill'])),
      );

  /// The master clinician still has to sign this version before using Steady.
  bool get waitingForSignature => canSign && !signed && text.isNotEmpty && version.isNotEmpty;
}

/// One signature, as the server keeps it.
class SignedAgreement {
  final String id, version, sha256, text, signerName, signerEmail, signature, ip, userAgent;
  final DateTime? signedAt;
  final AgreementDetails details;

  const SignedAgreement({
    required this.id,
    required this.version,
    this.sha256 = '',
    this.text = '',
    this.signerName = '',
    this.signerEmail = '',
    this.signature = '',
    this.ip = '',
    this.userAgent = '',
    this.signedAt,
    this.details = const AgreementDetails(),
  });

  factory SignedAgreement.fromJson(Map<String, dynamic> j) => SignedAgreement(
        id: '${j['id'] ?? ''}',
        version: '${j['version'] ?? ''}',
        sha256: '${j['sha256'] ?? ''}',
        text: '${j['text'] ?? ''}',
        signerName: '${j['signerName'] ?? ''}',
        signerEmail: '${j['signerEmail'] ?? ''}',
        signature: '${j['signature'] ?? ''}',
        ip: '${j['ip'] ?? ''}',
        userAgent: '${j['userAgent'] ?? ''}',
        signedAt: fromMs(j['signedAt']),
        details: AgreementDetails.fromJson(asMap(j['fields'])),
      );
}

/// The signed copy: the newest signature, and every one before it (newest first).
class SignedAgreements {
  final String version;
  final bool signed;
  final SignedAgreement? latest;
  final List<SignedAgreement> history;
  const SignedAgreements({required this.version, required this.signed, this.latest, this.history = const []});

  factory SignedAgreements.fromJson(Map<String, dynamic> j) => SignedAgreements(
        version: '${j['version'] ?? ''}',
        signed: j['signed'] == true,
        latest: j['latest'] is Map ? SignedAgreement.fromJson(asMap(j['latest'])) : null,
        history: asList(j['history']).map((h) => SignedAgreement.fromJson(asMap(h))).toList(),
      );
}

extension OperatorAgreementApi on Api {
  /// Any staff member: the text, and whether its current version is signed.
  Future<OperatorAgreement> operatorAgreement() async =>
      OperatorAgreement.fromJson(await pb.send<Map<String, dynamic>>('/api/steady/operator-agreement'));

  /// The master clinician signs [a] (the very version shown) after confirming it's them.
  Future<SignedAgreement> signOperatorAgreement(OperatorAgreement a, AgreementDetails details, {required String signature}) async {
    final res = await confirmed(() => pb.send<Map<String, dynamic>>('/api/steady/operator-agreement/sign', method: 'POST', body: {
          'version': a.version,
          'sha256': a.sha256,
          'fields': details.toSignJson(),
          'signature': signature.trim(),
          'authorised': true,
        }));
    return SignedAgreement.fromJson(res);
  }

  /// The master clinician, the practice admin and OpenWorks support: what was signed.
  Future<SignedAgreements> signedOperatorAgreement() async =>
      SignedAgreements.fromJson(await pb.send<Map<String, dynamic>>('/api/steady/operator-agreement/signed'));
}

/// One block of the agreement's text: the title, a heading, a list item or a paragraph. The
/// text uses only these (server/pb_hooks/content/operator-agreement.md).
enum AgreementBlockKind { title, heading, item, paragraph }

class AgreementBlock {
  final AgreementBlockKind kind;
  final String text;
  const AgreementBlock(this.kind, this.text);
}

List<AgreementBlock> agreementBlocks(String text) {
  final out = <AgreementBlock>[];
  final para = <String>[];
  void flush() {
    if (para.isNotEmpty) out.add(AgreementBlock(AgreementBlockKind.paragraph, para.join(' ')));
    para.clear();
  }

  for (final raw in text.replaceAll('\r\n', '\n').split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) {
      flush();
    } else if (line.startsWith('## ')) {
      flush();
      out.add(AgreementBlock(AgreementBlockKind.heading, line.substring(3).trim()));
    } else if (line.startsWith('# ')) {
      flush();
      out.add(AgreementBlock(AgreementBlockKind.title, line.substring(2).trim()));
    } else if (line.startsWith('- ')) {
      flush();
      out.add(AgreementBlock(AgreementBlockKind.item, line.substring(2).trim()));
    } else {
      para.add(line);
    }
  }
  flush();
  return out;
}

/// The Schedule as label and value pairs, for the screen and the PDF.
List<(String, String)> scheduleRows(SignedAgreement s) {
  final d = s.details;
  final officer = d.officerIsMaster
      ? '${d.officerName.isEmpty ? s.signerName : d.officerName}, the master clinician'
          '${d.officerEmail.isEmpty ? '' : ' (${d.officerEmail})'}'
      : [d.officerName, d.officerEmail, d.officerPhone].where((x) => x.isNotEmpty).join(', ');
  return [
    ('Practice', d.practiceName),
    ('Registration or practice number', d.registration),
    ('Physical address', d.address),
    ('Contact', [d.email, d.phone].where((x) => x.isNotEmpty).join(', ')),
    ('Information Officer', officer),
    ('Signed by', '${s.signature}${s.signerEmail.isEmpty ? '' : ' (account ${s.signerName}, ${s.signerEmail})'}'),
    ('Signed on', s.signedAt == null ? '' : agreementDateTime(s.signedAt!)),
  ];
}

const _months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

String agreementDateTime(DateTime t) {
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.day} ${_months[l.month - 1]} ${l.year} at ${two(l.hour)}:${two(l.minute)}';
}
