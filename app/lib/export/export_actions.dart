// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/api.dart';
import '../ui/widgets.dart';
import 'export_data.dart';
import 'report_pdf.dart';
import 'save_file.dart';
import 'workbook.dart';

const _xlsx = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

Future<bool> _confirm(BuildContext context, String what) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('Export $what'),
      content: const Text('The file holds confidential health information. Save it to the patient file or the '
          'practice\'s records, not to email, chat or a shared folder. The export is noted in the audit log.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Export')),
      ],
    ),
  );
  return ok == true;
}

Future<void> _run(BuildContext context, Future<void> Function() fn) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('Preparing the export...')));
  try {
    await fn();
    messenger.hideCurrentSnackBar();
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(errorText(e))));
  }
}

/// A PDF report with charts for one patient.
Future<void> exportPatientPdf(BuildContext context, String patientId) async {
  final api = AppScope.api(context);
  if (!await _confirm(context, 'a PDF report')) return;
  if (!context.mounted) return;
  await _run(context, () async {
    final bundle = ExportBundle.fromJson(await api.exportPatient(patientId));
    if (bundle.patients.isEmpty) throw const FormatException('Nothing to export.');
    final p = bundle.patients.first;
    final bytes = await buildPdfReport(bundle, p);
    await saveBytes(bytes, 'steady-${fileSafe(p.name)}-${dayText(bundle.generatedAt)}.pdf', 'application/pdf',
        subject: 'Steady report: ${p.name}');
  });
}

/// An Excel workbook for one patient, or all of this psychologist's patients when [patientId] is null.
Future<void> exportExcel(BuildContext context, {String? patientId}) async {
  final api = AppScope.api(context);
  if (!await _confirm(context, patientId == null ? 'all your patients to Excel' : 'to Excel')) return;
  if (!context.mounted) return;
  await _run(context, () async {
    final bundle = ExportBundle.fromJson(patientId == null ? await api.exportAll() : await api.exportPatient(patientId));
    final name = patientId == null || bundle.patients.isEmpty ? 'all-patients' : fileSafe(bundle.patients.first.name);
    await saveBytes(buildWorkbook(bundle), 'steady-$name-${dayText(bundle.generatedAt)}.xlsx', _xlsx, subject: 'Steady export');
  });
}

/// Shows a temporary password once, for the person who reset it to pass on.
Future<void> showTemporaryPassword(BuildContext context, String name, String password) => showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Temporary password for $name'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          SelectableText(password, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700, letterSpacing: 1.5, fontFamily: 'monospace')),
          const SizedBox(height: 12),
          const Text('Give it to them by phone or in person, not by email or chat. They\'re signed out everywhere now, '
              'and choose their own password when they sign in with this one. It isn\'t shown again.'),
        ]),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Done'))],
      ),
    );

/// Asks, then resets someone's password and shows the temporary one.
Future<void> resetPasswordFlow(BuildContext context, {required String userId, required String name, bool staff = false}) async {
  var twoStep = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setLocal) => AlertDialog(
        title: Text('Reset $name\'s password?'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('They\'ll be signed out on every device and get a temporary password from you.'),
          if (staff)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: twoStep,
              onChanged: (v) => setLocal(() => twoStep = v == true),
              title: const Text('Also reset two-step sign-in (lost phone)'),
            ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Reset')),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return;
  try {
    final pw = await AppScope.api(context).resetPassword(userId, twoStep: twoStep);
    if (context.mounted) await showTemporaryPassword(context, name, pw);
  } catch (e) {
    if (context.mounted) showSnack(context, errorText(e));
  }
}
