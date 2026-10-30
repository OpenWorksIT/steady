// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/api.dart';
import '../ui/widgets.dart';
import 'export_data.dart';
import 'heidi_pdf.dart';
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
  final logoPath = AppScope.of(context).config.brandLogo;
  if (!await _confirm(context, 'a PDF report')) return;
  if (!context.mounted) return;
  await _run(context, () async {
    final bundle = ExportBundle.fromJson(await api.exportPatient(patientId));
    if (bundle.patients.isEmpty) throw const FormatException('Nothing to export.');
    final p = bundle.patients.first;
    final logo = await api.brandLogo(logoPath);
    final bytes = await buildPdfReport(bundle, p, practiceLogo: logo);
    await saveBytes(bytes, 'steady-${fileSafe(p.name)}-${dayText(bundle.generatedAt)}.pdf', 'application/pdf',
        subject: 'Steady report: ${p.name}');
  });
}

/// A text-first PDF for Heidi (the practice's AI scribe) to read as session context. Offers
/// "since the last export" (only what's new), "everything", or chosen dates.
Future<void> exportHeidiPdf(BuildContext context, String patientId) async {
  final api = AppScope.api(context);
  HeidiMark? last;
  try {
    last = HeidiMark.fromJson(await api.lastHeidiExport(patientId));
  } catch (e) {
    if (context.mounted) showSnack(context, errorText(e));
    return;
  }
  if (!context.mounted) return;
  final today = DateTime.now();
  final lastTo = last == null ? null : DateTime.tryParse(last.to);
  final nextFrom = lastTo?.add(const Duration(days: 1));
  final nothingNew = nextFrom != null && dayText(nextFrom).compareTo(dayText(today)) > 0;
  var kind = last != null && !nothingNew ? HeidiKind.since : HeidiKind.all;
  DateTimeRange? chosen;
  final go = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setLocal) => AlertDialog(
        title: const Text('Export for Heidi'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('A PDF written for Heidi to read as context: how to read it, the data with dates, and what not to infer. '
                'Add it to the session in Heidi.'),
            const SizedBox(height: 10),
            for (final o in [
              if (last != null)
                (
                  HeidiKind.since,
                  'Since the last export',
                  nothingNew ? 'The last export already covers today' : 'From ${dayText(nextFrom!)}: part ${last.part + 1}, adds to the earlier file',
                  !nothingNew,
                ),
              (HeidiKind.all, 'Everything', 'From when they joined (starts a new series)', true),
              (HeidiKind.range, 'Choose dates', chosen == null ? 'Not part of the series' : '${dayText(chosen!.start)} to ${dayText(chosen!.end)}', true),
            ])
              ListTile(
                contentPadding: EdgeInsets.zero,
                enabled: o.$4,
                leading: Icon(kind == o.$1 ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    color: kind == o.$1 ? Theme.of(c).colorScheme.primary : null),
                title: Text(o.$2),
                subtitle: Text(o.$3),
                onTap: () => setLocal(() => kind = o.$1),
              ),
            if (kind == HeidiKind.range)
              TextButton.icon(
                icon: const Icon(Icons.date_range),
                label: const Text('Pick the dates'),
                onPressed: () async {
                  final r = await showDateRangePicker(context: c, firstDate: DateTime(2024), lastDate: today, initialDateRange: chosen);
                  if (r != null) setLocal(() => chosen = r);
                },
              ),
            const SizedBox(height: 6),
            Text('Tip: in Heidi, link the session to the patient\'s profile, so each new file adds to what Heidi already has.',
                style: Theme.of(c).textTheme.bodySmall),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: kind == HeidiKind.range && chosen == null ? null : () => Navigator.pop(c, true), child: const Text('Export')),
        ],
      ),
    ),
  );
  if (go != true || !context.mounted) return;
  if (!await _confirm(context, 'for Heidi')) return;
  if (!context.mounted) return;
  await _run(context, () async {
    final from = switch (kind) { HeidiKind.since => dayText(nextFrom!), HeidiKind.range => dayText(chosen!.start), HeidiKind.all => null };
    final to = kind == HeidiKind.range ? dayText(chosen!.end) : dayText(today);
    final bundle = ExportBundle.fromJson(await api.exportPatient(patientId, from: from, to: to));
    if (bundle.patients.isEmpty) throw const FormatException('Nothing to export.');
    final p = bundle.patients.first;
    final bytes = await buildHeidiPdf(bundle, p, kind: kind, previous: last);
    final part = kind == HeidiKind.since && last != null ? '-part${last.part + 1}' : '';
    await saveBytes(bytes, 'steady-heidi-${fileSafe(p.name)}-${dayText(bundle.generatedAt)}$part.pdf', 'application/pdf',
        subject: 'Steady for Heidi: ${p.name}');
    if (kind != HeidiKind.range) {
      await api.markHeidiExport(patientId,
          kind: kind == HeidiKind.since ? 'since' : 'all', from: p.from == null ? (from ?? dayText(today)) : dayText(p.from!), to: to);
    }
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
