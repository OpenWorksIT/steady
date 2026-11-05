// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The operator agreement between the practice and OpenWorks IT (POPIA section 21). OpenWorks runs
// the practice's Steady server, so the law asks for a written contract between them: the master
// clinician signs it here before using Steady, and again when a new version comes. Other staff
// aren't asked. Settings > Practice > Operator agreement shows what was signed, with a PDF.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_state.dart';
import '../../export/agreement_pdf.dart';
import '../../export/save_file.dart';
import '../../services/api.dart';
import '../../services/operator_agreement.dart';
import '../theme.dart';
import '../widgets.dart';

/// Before the master clinician uses Steady: the operator agreement, if its current version isn't
/// signed yet. Everyone else goes straight on, and so does the master clinician if the server
/// can't be asked (offline, or a server from before the agreement).
class OperatorAgreementGate extends StatefulWidget {
  final Widget child;
  const OperatorAgreementGate({required this.child, super.key});
  @override
  State<OperatorAgreementGate> createState() => _OperatorAgreementGateState();
}

class _OperatorAgreementGateState extends State<OperatorAgreementGate> {
  String _checkedFor = '';
  bool _checked = false;
  OperatorAgreement? _waiting;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final api = AppScope.api(context);
    final who = '${api.serverUrl}|${api.myId}';
    if (!api.isMaster || who == _checkedFor) return;
    _checkedFor = who;
    _checked = false;
    _waiting = null;
    _load(api);
  }

  Future<void> _load(Api api) async {
    OperatorAgreement? a;
    try {
      a = await api.operatorAgreement().timeout(const Duration(seconds: 15));
    } catch (_) {
      a = null;
    }
    if (!mounted) return;
    final waiting = a != null && a.waitingForSignature ? a : null;
    setState(() {
      _checked = true;
      _waiting = waiting;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!AppScope.api(context).isMaster) return widget.child;
    if (!_checked) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final a = _waiting;
    if (a == null) return widget.child;
    return OperatorAgreementSignScreen(agreement: a, onSigned: () => setState(() => _waiting = null));
  }
}

/// The agreement's text: headings, paragraphs and lists, selectable.
class AgreementText extends StatelessWidget {
  final String text;
  const AgreementText(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final body = context.tt.bodyMedium?.copyWith(height: 1.45);
    return SelectionArea(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final b in agreementBlocks(text)) _block(context, b, body),
      ]),
    );
  }

  Widget _block(BuildContext context, AgreementBlock b, TextStyle? body) {
    switch (b.kind) {
      case AgreementBlockKind.title:
        return Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(b.text, style: context.tt.titleLarge));
      case AgreementBlockKind.heading:
        return Padding(padding: const EdgeInsets.only(top: 14, bottom: 6), child: Text(b.text, style: context.tt.titleMedium));
      case AgreementBlockKind.item:
        return Padding(
          padding: const EdgeInsets.only(left: 6, bottom: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 16, child: Text('•', style: body)),
            Expanded(child: Text(b.text, style: body)),
          ]),
        );
      case AgreementBlockKind.paragraph:
        return Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(b.text, style: body));
    }
  }
}

/// The master clinician reads the agreement, fills in the practice's details and signs.
/// [onSigned]: on to Steady (the gate). Without it (signing again from Settings), it closes
/// with true once signed.
class OperatorAgreementSignScreen extends StatefulWidget {
  final OperatorAgreement agreement;
  final VoidCallback? onSigned;
  const OperatorAgreementSignScreen({required this.agreement, this.onSigned, super.key});
  @override
  State<OperatorAgreementSignScreen> createState() => _OperatorAgreementSignScreenState();
}

class _OperatorAgreementSignScreenState extends State<OperatorAgreementSignScreen> {
  late final TextEditingController _name, _registration, _address, _email, _phone;
  late final TextEditingController _officerName, _officerEmail, _officerPhone;
  final _signature = TextEditingController();
  bool _officerIsMaster = true;
  bool _authorised = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final p = widget.agreement.prefill;
    _name = TextEditingController(text: p.practiceName);
    _registration = TextEditingController(text: p.registration);
    _address = TextEditingController(text: p.address);
    _email = TextEditingController(text: p.email);
    _phone = TextEditingController(text: p.phone);
    _officerIsMaster = p.officerIsMaster;
    _officerName = TextEditingController(text: p.officerIsMaster ? '' : p.officerName);
    _officerEmail = TextEditingController(text: p.officerIsMaster ? '' : p.officerEmail);
    _officerPhone = TextEditingController(text: p.officerIsMaster ? '' : p.officerPhone);
  }

  @override
  void dispose() {
    for (final c in [_name, _registration, _address, _email, _phone, _officerName, _officerEmail, _officerPhone, _signature]) {
      c.dispose();
    }
    super.dispose();
  }

  static final _emailOk = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  String? _check() {
    final missing = <String>[
      if (_name.text.trim().isEmpty) "the practice's legal name",
      if (_registration.text.trim().isEmpty) 'the registration or practice number',
      if (_address.text.trim().isEmpty) 'the physical address',
      if (_email.text.trim().isEmpty) 'the contact email',
      if (_phone.text.trim().isEmpty) 'the contact phone number',
      if (!_officerIsMaster && _officerName.text.trim().isEmpty) "the Information Officer's name",
      if (!_officerIsMaster && _officerEmail.text.trim().isEmpty) "the Information Officer's email",
      if (!_officerIsMaster && _officerPhone.text.trim().isEmpty) "the Information Officer's phone number",
      if (_signature.text.trim().length < 3) 'your full name, as your signature',
    ];
    if (missing.isNotEmpty) return 'Please fill in ${missing.join(', ')}.';
    if (!_emailOk.hasMatch(_email.text.trim())) return "The contact email doesn't look right.";
    if (!_officerIsMaster && !_emailOk.hasMatch(_officerEmail.text.trim())) return "The Information Officer's email doesn't look right.";
    return null;
  }

  Future<void> _sign() async {
    final problem = _check();
    setState(() => _error = problem);
    if (problem != null) return;
    final api = AppScope.api(context);
    final details = AgreementDetails(
      practiceName: _name.text.trim(),
      registration: _registration.text.trim(),
      address: _address.text.trim(),
      email: _email.text.trim(),
      phone: _phone.text.trim(),
      officerIsMaster: _officerIsMaster,
      officerName: _officerName.text.trim(),
      officerEmail: _officerEmail.text.trim(),
      officerPhone: _officerPhone.text.trim(),
    );
    try {
      await api.signOperatorAgreement(widget.agreement, details, signature: _signature.text);
      if (!mounted) return;
      showSnack(context, 'Signed. The signed copy is under Settings > Practice > Operator agreement.');
      final done = widget.onSigned;
      if (done != null) {
        done();
      } else {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  Widget _field(TextEditingController c, String label, int max, {TextInputType? type, String? helper, int lines = 1}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          keyboardType: type,
          minLines: lines,
          maxLines: lines,
          inputFormatters: [LengthLimitingTextInputFormatter(max)],
          textCapitalization: type == null ? TextCapitalization.words : TextCapitalization.none,
          decoration: InputDecoration(labelText: label, helperText: helper),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final a = widget.agreement;
    final gate = widget.onSigned != null;
    final again = a.lastSignedVersion.isNotEmpty && a.lastSignedVersion != a.version;
    final intro = !gate
        ? 'Signing again records new details, such as a new Information Officer. The newest signature counts.'
        : again
            ? 'OpenWorks IT has a new version of the operator agreement (version ${a.version}; the practice signed version '
                '${a.lastSignedVersion}). Please read it and sign it to keep using Steady.'
            : 'OpenWorks IT runs the practice\'s Steady server, so POPIA asks for a written agreement between the practice and '
                'OpenWorks about how it looks after the practice\'s information. As the master clinician, please read it, '
                'fill in the practice\'s details and sign it before you use Steady.';
    return Scaffold(
      appBar: AppBar(title: const Text('Operator agreement'), automaticallyImplyLeading: !gate),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(22, 12, 22, 28), children: [
          Text(intro, style: context.tt.bodyLarge),
          const SizedBox(height: 16),
          Card(child: Padding(padding: const EdgeInsets.all(16), child: AgreementText(a.text))),
          const SizedBox(height: 20),
          Text('The practice', style: context.tt.titleMedium),
          const SizedBox(height: 4),
          Text("As they should appear in the agreement's Schedule.", style: TextStyle(color: context.sc.ink2)),
          const SizedBox(height: 12),
          _field(_name, "Practice's legal name", 160),
          _field(_registration, 'Registration or practice number', 60, type: TextInputType.text,
              helper: 'Company registration number, or the practice number for a sole practitioner'),
          _field(_address, 'Physical address', 300, lines: 2),
          _field(_email, 'Contact email', 200, type: TextInputType.emailAddress),
          _field(_phone, 'Contact phone number', 30, type: TextInputType.phone),
          const SizedBox(height: 8),
          Text('Information Officer', style: context.tt.titleMedium),
          const SizedBox(height: 4),
          Text("The practice's contact for POPIA, and the first person OpenWorks tells about a security problem.",
              style: TextStyle(color: context.sc.ink2)),
          CheckboxListTile(
            value: _officerIsMaster,
            onChanged: (v) => setState(() => _officerIsMaster = v ?? true),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            title: Text("${state.api.myName}, the master clinician, is the practice's Information Officer"),
          ),
          if (!_officerIsMaster) ...[
            const SizedBox(height: 4),
            _field(_officerName, "Information Officer's name", 120),
            _field(_officerEmail, "Information Officer's email", 200, type: TextInputType.emailAddress),
            _field(_officerPhone, "Information Officer's phone number", 30, type: TextInputType.phone),
          ],
          const SizedBox(height: 8),
          Text('Sign', style: context.tt.titleMedium),
          const SizedBox(height: 12),
          _field(_signature, 'Your full name, as your signature', 120),
          CheckboxListTile(
            value: _authorised,
            onChanged: (v) => setState(() => _authorised = v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            title: const Text("I'm authorised to sign for the practice and agree to this agreement"),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: context.cs.error)),
          ],
          const SizedBox(height: 12),
          BusyButton(label: 'Sign', onPressed: _authorised ? _sign : null),
          const SizedBox(height: 10),
          Text("Steady asks you to confirm it's you, then keeps the signed copy. You, the practice admin and OpenWorks can "
              'open it under Settings > Practice, and download it as a PDF.',
              style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
          if (gate) ...[
            const SizedBox(height: 16),
            Text('Questions first? Contact OpenWorks IT at info@openworks.co.za. Until it is signed you can sign out.',
                style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: () => state.signOut(), child: const Text('Sign out')),
            ),
          ],
        ]),
      ),
    );
  }
}

/// Settings > Practice > Operator agreement: what was signed (master clinician, practice
/// admin, OpenWorks support), with a PDF to download. The master clinician can sign again with
/// new details.
class OperatorAgreementCopyScreen extends StatefulWidget {
  const OperatorAgreementCopyScreen({super.key});
  @override
  State<OperatorAgreementCopyScreen> createState() => _OperatorAgreementCopyScreenState();
}

class _OperatorAgreementCopyScreenState extends State<OperatorAgreementCopyScreen> {
  Key _key = UniqueKey();

  Future<void> _pdf(SignedAgreement s) async {
    final bytes = await buildAgreementPdf(s);
    final name = 'operator-agreement-v${s.version}-${s.signedAt == null ? 'signed' : s.signedAt!.toIso8601String().substring(0, 10)}.pdf';
    await saveBytes(bytes, name, 'application/pdf', subject: 'Operator agreement, version ${s.version}');
  }

  Future<void> _signAgain() async {
    final api = AppScope.api(context);
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final OperatorAgreement a;
    try {
      a = await api.operatorAgreement();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(errorText(e))));
      return;
    }
    final signed = await nav.push<bool>(MaterialPageRoute(builder: (_) => OperatorAgreementSignScreen(agreement: a)));
    if (signed == true && mounted) setState(() => _key = UniqueKey());
  }

  @override
  Widget build(BuildContext context) {
    final api = AppScope.api(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Operator agreement')),
      body: Loader<SignedAgreements>(
        key: _key,
        load: () => api.signedOperatorAgreement(),
        builder: (context, data, reload) {
          final s = data.latest;
          return ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 28), children: [
            if (s == null)
              Text('Not signed yet. The master clinician is asked to sign it the next time they open Steady.',
                  style: context.tt.bodyLarge)
            else ...[
              Text(
                data.signed
                    ? 'Version ${s.version}, signed by ${s.signature}${s.signedAt == null ? '' : ' on ${agreementDateTime(s.signedAt!)}'}.'
                    : 'Version ${s.version} was signed${s.signedAt == null ? '' : ' on ${agreementDateTime(s.signedAt!)}'}. '
                        'A new version (${data.version}) waits for the master clinician.',
                style: context.tt.bodyLarge,
              ),
              const SizedBox(height: 12),
              BusyButton(label: 'Download PDF', onPressed: () => _pdf(s)),
              if (api.isMaster)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(onPressed: _signAgain, child: const Text('Sign again with new details')),
                ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Schedule, as given when signing', style: context.tt.titleMedium),
                    const SizedBox(height: 8),
                    for (final r in scheduleRows(s)) _Fact(r.$1, r.$2),
                  ]),
                ),
              ),
              const SizedBox(height: 12),
              Card(child: Padding(padding: const EdgeInsets.all(16), child: AgreementText(s.text))),
              const SizedBox(height: 12),
              Text('Record of the signature', style: context.tt.titleSmall),
              const SizedBox(height: 6),
              _Fact('Text fingerprint (SHA-256)', s.sha256),
              _Fact('Internet address', s.ip),
              _Fact('App', s.userAgent),
              if (data.history.length > 1) ...[
                const SizedBox(height: 12),
                Text('Every signature', style: context.tt.titleSmall),
                const SizedBox(height: 6),
                for (final h in data.history)
                  _Fact('Version ${h.version}', '${h.signature}${h.signedAt == null ? '' : ', ${agreementDateTime(h.signedAt!)}'}'),
              ],
            ],
          ]);
        },
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  final String label, value;
  const _Fact(this.label, this.value);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
          SelectableText(value.isEmpty ? '-' : value),
        ]),
      );
}
