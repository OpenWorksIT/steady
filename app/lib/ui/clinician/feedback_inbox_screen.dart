// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Settings > Feedback (master psychologist and administrators): everything sent with the Feedback
// button, newest first, to read and mark as seen or done. OpenWorks IT reads the same with
// deploy/feedback.sh on the server.
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../services/api.dart';
import '../theme.dart';

const _kindNames = {'love': 'Love this', 'dislike': "Don't like this", 'bug': 'Bug found'};
const _kindIcons = {'love': Icons.favorite_outline, 'dislike': Icons.thumb_down_outlined, 'bug': Icons.bug_report_outlined};

String _when(String iso) {
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return '';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.day}/${d.month}/${d.year} ${two(d.hour)}:${two(d.minute)}';
}

class FeedbackInboxScreen extends StatefulWidget {
  const FeedbackInboxScreen({super.key});
  @override
  State<FeedbackInboxScreen> createState() => _FeedbackInboxScreenState();
}

class _FeedbackInboxScreenState extends State<FeedbackInboxScreen> {
  String _filter = 'open';
  List<Map<String, dynamic>>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await AppScope.api(context).feedbackList(_filter);
      if (mounted) {
        setState(() {
          _items = items;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: const Text('Feedback')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          Text('From the Feedback button on staff screens. OpenWorks IT sees these too.', style: TextStyle(color: context.sc.ink2)),
          const SizedBox(height: 10),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'open', label: Text('To look at')),
              ButtonSegment(value: 'done', label: Text('Done')),
              ButtonSegment(value: 'all', label: Text('All')),
            ],
            selected: {_filter},
            onSelectionChanged: (v) {
              setState(() {
                _filter = v.first;
                _items = null;
              });
              _load();
            },
          ),
          const SizedBox(height: 10),
          if (_error != null) Text(_error!, style: TextStyle(color: context.cs.error)),
          if (items == null && _error == null) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          if (items != null && items.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Text('Nothing here.', style: TextStyle(color: context.sc.ink3))),
          for (final i in items ?? const <Map<String, dynamic>>[])
            Card(
              child: ListTile(
                leading: Icon(_kindIcons[i['kind']] ?? Icons.feedback_outlined, color: i['kind'] == 'bug' ? context.sc.alert : context.cs.primary),
                title: Text('${i['message']}'.isEmpty ? _kindNames[i['kind']] ?? '' : '${i['message']}', maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text('${_kindNames[i['kind']]} · ${i['who']} · ${_when('${i['at']}')}\n${i['screen']}${i['hasScreenshot'] == true ? ' · screenshot' : ''}'
                    '${i['status'] == 'seen' ? ' · seen' : ''}'),
                isThreeLine: true,
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => FeedbackReportScreen(id: '${i['id']}')));
                  _load();
                },
              ),
            ),
        ]),
      ),
    );
  }
}

class FeedbackReportScreen extends StatefulWidget {
  final String id;
  const FeedbackReportScreen({required this.id, super.key});
  @override
  State<FeedbackReportScreen> createState() => _FeedbackReportScreenState();
}

class _FeedbackReportScreenState extends State<FeedbackReportScreen> {
  Map<String, dynamic>? _r;
  String? _error;
  final _note = TextEditingController();
  Future<dynamic>? _shot;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final api = AppScope.api(context);
    try {
      final r = await api.feedbackGet(widget.id);
      if (!mounted) return;
      setState(() {
        _r = r;
        _note.text = '${r['note'] ?? ''}';
        if (r['hasScreenshot'] == true) _shot = api.feedbackScreenshot(widget.id);
      });
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  Future<void> _mark(String status) async {
    try {
      await AppScope.api(context).feedbackSetStatus(widget.id, status, _note.text.trim());
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    final client = r?['client'] is Map ? Map<String, dynamic>.from(r!['client'] as Map) : const <String, dynamic>{};
    final trail = ((r?['trail'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    return Scaffold(
      appBar: AppBar(title: Text(r == null ? 'Feedback' : _kindNames['${r['kind']}'] ?? 'Feedback')),
      body: r == null
          ? Center(child: _error != null ? Text(_error!) : const CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
              Text('${r['who']} · ${_when('${r['at']}')}', style: TextStyle(color: context.sc.ink2)),
              Text('On ${r['screen']} · app ${client['build'] ?? ''} on ${client['platform'] ?? ''}${client['screenSize'] != null ? ', ${client['screenSize']}' : ''}',
                  style: TextStyle(color: context.sc.ink3)),
              const SizedBox(height: 12),
              SelectableText('${r['message']}'.isEmpty ? '(no words)' : '${r['message']}', style: context.tt.bodyLarge),
              if (_shot != null) ...[
                const SizedBox(height: 14),
                Text(r['screenshotMasked'] == true ? 'Screenshot (blurred)' : 'Screenshot (not blurred)', style: context.tt.titleSmall),
                const SizedBox(height: 6),
                FutureBuilder<dynamic>(
                  future: _shot,
                  builder: (_, snap) => snap.connectionState != ConnectionState.done
                      ? const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()))
                      : snap.data == null
                          ? Text("The screenshot couldn't be loaded.", style: TextStyle(color: context.sc.ink3))
                          : ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.memory(snap.data, fit: BoxFit.contain)),
                ),
              ],
              if (trail.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('Steps before it (oldest first)', style: context.tt.titleSmall),
                const SizedBox(height: 4),
                for (final t in trail)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text('${'${t['at']}'.length >= 19 ? '${t['at']}'.substring(11, 19) : ''}  ${t['kind']}  ${t['detail']}',
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5)),
                  ),
              ],
              const SizedBox(height: 16),
              TextField(controller: _note, maxLength: 1000, decoration: const InputDecoration(labelText: 'Note (optional)', border: OutlineInputBorder())),
              if (_error != null) Text(_error!, style: TextStyle(color: context.cs.error)),
              Row(children: [
                Expanded(child: OutlinedButton(onPressed: () => _mark('seen'), child: const Text('Mark seen'))),
                const SizedBox(width: 10),
                Expanded(child: FilledButton(onPressed: () => _mark('done'), child: const Text('Mark done'))),
              ]),
            ]),
    );
  }
}
