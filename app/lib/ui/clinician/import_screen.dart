// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../models.dart';
import '../../services/api.dart';
import '../theme.dart';
import '../widgets.dart';

class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});
  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  final _paste = TextEditingController();
  bool _ownWork = false;
  bool _changed = false;
  String? _busy; // activity being imported

  @override
  void dispose() {
    _paste.dispose();
    super.dispose();
  }

  void _done(Map<String, dynamic> res) {
    _changed = true;
    final status = res['licenceStatus'];
    showSnack(
      context,
      status == 'review'
          ? 'Imported ${res['name']} (${res['items']} questions). Confirm its licence in the library before sending.'
          : 'Imported ${res['name']} (${res['items']} questions). It is ready to send.',
    );
  }

  Future<void> _importJson(String text) async {
    Object? parsed;
    try {
      parsed = jsonDecode(text);
    } catch (_) {
      showSnack(context, "That isn't valid JSON.");
      return;
    }
    final data = asMap(parsed);
    if (data.isEmpty) {
      showSnack(context, 'Expected a JSON object.');
      return;
    }
    final format = data['resourceType'] == 'Questionnaire' ? 'fhir' : 'steady';
    final api = AppScope.api(context);
    try {
      final res = await api.importInstrument(format: format, data: data, ownWork: format == 'steady' && _ownWork);
      if (mounted) _done(res);
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    }
  }

  Future<void> _pickFile() async {
    try {
      final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['json']);
      if (files.isEmpty) return;
      final bytes = await files.first.readAsBytes();
      if (bytes.length > 400000) {
        if (mounted) showSnack(context, 'That file is too large for a questionnaire.');
        return;
      }
      if (mounted) await _importJson(utf8.decode(bytes, allowMalformed: true));
    } catch (e) {
      if (mounted) showSnack(context, "Couldn't open that file.");
    }
  }

  Future<void> _importRepro(String activity) async {
    setState(() => _busy = activity);
    final api = AppScope.api(context);
    try {
      final res = await api.importInstrument(format: 'reproschema', activity: activity);
      if (mounted) _done(res);
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Import')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            const SectionHeader('Open library: ReproSchema'),
            Text(
              'Validated questionnaires from an open-source research library. Each one carries its own licence, '
              'so imports wait in your library until you confirm the practice may use them.',
              style: context.tt.bodySmall?.copyWith(color: context.sc.ink2),
            ),
            const SizedBox(height: 8),
            Loader<List<({String activity, String label, String status, bool imported})>>(
              load: AppScope.api(context).reproCatalog,
              builder: (context, items, reload) => ListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (final it in items)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(it.label),
                      subtitle: Text(switch (it.status) {
                        'public' => 'Listed as free to use',
                        'blocked' => 'Copyright protected: not available',
                        _ => 'Check the licence before use',
                      }),
                      trailing: it.imported
                          ? const FlagChip('In library', Severity.none)
                          : it.status == 'blocked'
                              ? const FlagChip('Blocked', Severity.alert)
                              : _busy == it.activity
                                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                                  : TextButton(
                                      onPressed: _busy != null
                                          ? null
                                          : () async {
                                              await _importRepro(it.activity);
                                              reload();
                                            },
                                      child: const Text('Import'),
                                    ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const SectionHeader('From a file'),
            Text('A Steady questionnaire (.json) or a FHIR Questionnaire resource (.json).',
                style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _ownWork,
              onChanged: (v) => setState(() => _ownWork = v ?? false),
              title: const Text('This is the practice\'s own questionnaire'),
              subtitle: const Text('Skips the licence check. Only tick this for material you wrote.'),
            ),
            OutlinedButton.icon(onPressed: _pickFile, icon: const Icon(Icons.upload_file), label: const Text('Choose a file')),
            const SizedBox(height: 16),
            const SectionHeader('Or paste JSON'),
            TextField(controller: _paste, maxLines: 6, decoration: const InputDecoration(hintText: '{ "resourceType": "Questionnaire", ... }')),
            const SizedBox(height: 8),
            BusyButton(label: 'Import pasted JSON', onPressed: () => _importJson(_paste.text)),
          ],
        ),
      ),
    );
  }
}
