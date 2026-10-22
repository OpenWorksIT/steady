// SPDX-License-Identifier: AGPL-3.0-or-later
// Words of encouragement for the daily start screen of this psychologist's patients, shown
// alongside the ones built into Steady (content/daily_words.dart).
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../content/daily_words.dart';
import '../../services/api.dart';
import '../theme.dart';
import '../widgets.dart';

class DailyWordsScreen extends StatefulWidget {
  const DailyWordsScreen({super.key});
  @override
  State<DailyWordsScreen> createState() => _DailyWordsScreenState();
}

class _DailyWordsScreenState extends State<DailyWordsScreen> {
  Key _key = UniqueKey();
  void _reload() => setState(() => _key = UniqueKey());

  Future<void> _add() async {
    final text = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Add words for the daily start'),
        content: TextField(
          controller: text,
          autofocus: true,
          maxLength: 240,
          maxLines: 3,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'A sentence or two',
            helperText: 'Your patients see one each day, before their check-in. If you quote someone, add their name in the text.',
            helperMaxLines: 3,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Add')),
        ],
      ),
    );
    final t = text.text.trim();
    text.dispose();
    if (ok != true || t.length < 3 || !mounted) return;
    try {
      await AppScope.api(context).addQuote(t);
      _reload();
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = AppScope.api(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Daily words')),
      floatingActionButton: FloatingActionButton.extended(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Add')),
      body: Loader<List<({String id, String text, String author, bool active})>>(
        key: _key,
        load: api.quotes,
        builder: (context, mine, reload) => ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 96), children: [
          Text(
            'Each day your patients first see a few calm words and a breathing circle. Add your own here; '
            'they\'re mixed in with the ${dailyWords.length} that come with Steady.',
            style: TextStyle(color: context.sc.ink2),
          ),
          const SizedBox(height: 12),
          SectionHeader('Yours', trailing: '${mine.length}'),
          if (mine.isEmpty) Text('None yet.', style: TextStyle(color: context.sc.ink3)),
          for (final q in mine)
            Card(
              child: ListTile(
                title: Text(q.text),
                subtitle: q.active ? null : const Text('Hidden from patients'),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) async {
                    await guardedCall(context, () => v == 'toggle' ? api.setQuoteActive(q.id, !q.active) : api.deleteQuote(q.id));
                    reload();
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'toggle', child: Text(q.active ? 'Hide from patients' : 'Show to patients')),
                    const PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 16),
          const SectionHeader('Built into Steady'),
          for (final w in dailyWords)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Text(w, style: context.tt.bodyMedium?.copyWith(color: context.sc.ink2)),
            ),
        ]),
      ),
    );
  }
}

Future<void> guardedCall(BuildContext context, Future<void> Function() fn) async {
  try {
    await fn();
  } catch (e) {
    if (context.mounted) showSnack(context, errorText(e));
  }
}
