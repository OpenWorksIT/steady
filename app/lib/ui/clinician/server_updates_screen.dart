// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Settings > Server and updates, for the master clinician, administrators and psychologists marked serverAdmin. The server does the
// work (deploy/ctl/steady-ctl.sh, as root); this screen asks for it and shows how it went.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../build_info.dart';
import '../../services/api.dart';
import '../theme.dart';
import '../widgets.dart';

class ServerUpdatesScreen extends StatefulWidget {
  /// 'check' or 'update': start that straight away (from Settings' buttons).
  final String? ask;
  const ServerUpdatesScreen({this.ask, super.key});
  @override
  State<ServerUpdatesScreen> createState() => _ServerUpdatesScreenState();
}

class _ServerUpdatesScreenState extends State<ServerUpdatesScreen> {
  Map<String, dynamic>? _info;
  String? _error;
  bool _busy = false;
  DateTime? _updateAskedAt;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load().then((_) {
      if (mounted && widget.ask != null && _info?['managed'] == true && !_working) _ask(widget.ask!);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

  Future<void> _load() async {
    try {
      final info = await AppScope.api(context).systemStatus();
      if (!mounted) return;
      setState(() {
        _info = info;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      // during an update the server restarts for a minute or two; keep waiting quietly
      if (_waitingForUpdate) {
        setState(() => _error = null);
      } else {
        setState(() => _error = errorText(e));
      }
    }
    _schedule();
  }

  bool get _working {
    final st = _map(_info?['status']);
    return _info?['pending'] != null || st['checking'] != null || st['updating'] != null;
  }

  /// After "Update now", until the server reports an update that finished after the request
  /// (or 30 minutes pass). The server restarts in between, so requests fail for a while.
  bool get _waitingForUpdate {
    final asked = _updateAskedAt;
    if (asked == null) return false;
    if (DateTime.now().difference(asked) > const Duration(minutes: 30)) return false;
    if (_working) return true;
    final last = DateTime.tryParse('${_map(_map(_info?['status'])['lastUpdate'])['at'] ?? ''}');
    // allow a minute of clock difference between this phone and the server
    return last == null || last.isBefore(asked.toUtc().subtract(const Duration(minutes: 1)));
  }

  void _schedule() {
    _timer?.cancel();
    if (_working || _waitingForUpdate) {
      _timer = Timer(const Duration(seconds: 4), _load);
    } else {
      _updateAskedAt = null;
    }
  }

  Future<void> _ask(String action) async {
    if (action == 'update') {
      final go = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Update the server now?'),
          content: const Text('A copy of all data is saved on the server first. Steady then restarts, '
              'which takes a few minutes: people using it will see "can\'t reach the server" until it\'s back.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Update now')),
          ],
        ),
      );
      if (go != true || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      await AppScope.api(context).systemRequest(action);
      if (action == 'update') _updateAskedAt = DateTime.now();
      await _load();
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _when(Object? iso) {
    final d = DateTime.tryParse('${iso ?? ''}')?.toLocal();
    if (d == null) return '';
    final m = DateTime.now().difference(d).inMinutes;
    if (m < 1) return 'just now';
    if (m < 60) return '$m min ago';
    if (m < 24 * 60) return '${(m / 60).round()} h ago';
    return '${d.day}/${d.month}/${d.year} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  String _short(Object? sha) => '${sha ?? ''}'.length > 7 ? '$sha'.substring(0, 7) : '${sha ?? ''}';

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final st = _map(info?['status']);
    final check = _map(st['check']);
    final last = _map(st['lastUpdate']);
    final updating = _map(st['updating']);
    final behind = (check['behind'] as num?)?.toInt() ?? 0;
    final appCheck = _map(check['app']);
    final appNewer = '${appCheck['latest'] ?? ''}'.isNotEmpty && appCheck['latest'] != appCheck['current'];
    final changes = (check['changes'] is List ? check['changes'] as List : const []).map(_map).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Server and updates')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(18, 8, 18, 28), children: [
          if (_error != null) Text(_error!, style: TextStyle(color: context.cs.error)),
          if (info == null && _error == null) const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
          if (info != null && info['managed'] != true)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Updates from the app aren\'t set up on this server yet. '
                    'OpenWorks runs deploy/ctl/install.sh on the server once.', style: TextStyle(color: context.sc.ink2)),
              ),
            ),
          if (info != null && info['managed'] == true) ...[
            if (_working || _waitingForUpdate)
              Card(
                child: ListTile(
                  leading: const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
                  title: Text(updating.isNotEmpty
                      ? '${updating['step'] ?? 'Updating'}'
                      : st['checking'] != null
                          ? 'Checking for updates'
                          : info['pending'] == 'update'
                              ? 'Starting the update'
                              : _waitingForUpdate
                                  ? 'Restarting'
                                  : 'Checking for updates'),
                  subtitle: const Text('You can leave this screen; the server carries on.'),
                ),
              ),
            const SizedBox(height: 12),
            Text('Server', style: context.tt.titleMedium),
            const SizedBox(height: 4),
            if (check.isEmpty)
              Text('Not checked yet.', style: TextStyle(color: context.sc.ink2))
            else ...[
              Text(
                behind == 0 ? 'Up to date' : '$behind update${behind == 1 ? '' : 's'} available',
                style: context.tt.titleLarge?.copyWith(color: behind == 0 ? context.sc.calm : context.cs.primary),
              ),
              Text('Running ${_short(_map(check['current'])['sha'])}'
                  '${behind > 0 ? ', newest ${_short(_map(check['latest'])['sha'])}' : ''} · checked ${_when(check['at'])}',
                  style: TextStyle(color: context.sc.ink2)),
              if ('${check['error'] ?? ''}'.isNotEmpty)
                Text('Couldn\'t reach GitHub: ${check['error']}', style: TextStyle(color: context.cs.error)),
              if (changes.isNotEmpty) ...[
                const SizedBox(height: 10),
                for (final c in changes.take(12))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('• ${c['subject']}', style: context.tt.bodyMedium),
                  ),
                if (changes.length > 12) Text('and ${changes.length - 12} more', style: TextStyle(color: context.sc.ink3)),
              ],
            ],
            const SizedBox(height: 16),
            Text('Android app on the server', style: context.tt.titleMedium),
            const SizedBox(height: 4),
            Text(
              '${appCheck['current'] ?? ''}'.isEmpty
                  ? 'No Android build on the server yet${appNewer ? '; the next update adds one' : ''}.'
                  : 'Build ${appCheck['current']}${appNewer ? ' · build ${appCheck['latest']} comes with the next update' : ''}',
              style: TextStyle(color: context.sc.ink2),
            ),
            Text('This phone: ${kAppBuild.isEmpty ? 'a development build' : 'build $kAppBuild'}', style: TextStyle(color: context.sc.ink3)),
            const SizedBox(height: 20),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy || _working ? null : () => _ask('check'),
                  child: const Text('Check for updates'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _busy || _working || (behind == 0 && !appNewer) ? null : () => _ask('update'),
                  child: const Text('Update now'),
                ),
              ),
            ]),
            if (last.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text('Last update', style: context.tt.titleMedium),
              const SizedBox(height: 4),
              Text(
                last['ok'] == true
                    ? 'Updated ${_when(last['at'])} (${last['from']} → ${last['to']})'
                    : 'Failed ${_when(last['at'])}. ${last['message'] ?? 'Steady kept running on the previous version.'}',
                style: TextStyle(color: last['ok'] == true ? context.sc.calm : context.cs.error),
              ),
              if (last['ok'] != true && '${last['log'] ?? ''}'.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Details for OpenWorks'),
                  children: [SelectableText('${last['log']}', style: const TextStyle(fontFamily: 'monospace', fontSize: 11))],
                ),
            ],
          ],
        ]),
      ),
    );
  }
}

/// The version and the two update buttons, for Settings (master clinician and administrators).
/// The full progress and history are on [ServerUpdatesScreen].
class UpdateControls extends StatefulWidget {
  const UpdateControls({super.key});
  @override
  State<UpdateControls> createState() => _UpdateControlsState();
}

class _UpdateControlsState extends State<UpdateControls> {
  Map<String, dynamic>? _info;
  String? _error;

  Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final info = await AppScope.api(context).systemStatus();
      if (mounted) setState(() => _info = info);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  void _open(BuildContext context, {String? ask}) {
    final nav = Navigator.of(context);
    nav.pop();
    nav.push(MaterialPageRoute(builder: (_) => ServerUpdatesScreen(ask: ask)));
  }

  @override
  Widget build(BuildContext context) {
    final st = _map(_info?['status']);
    final check = _map(st['check']);
    final behind = (check['behind'] as num?)?.toInt() ?? 0;
    final sha = '${_map(check['current'])['sha'] ?? ''}';
    final managed = _info?['managed'] == true;
    final line = _error ??
        (_info == null
            ? 'Checking the server...'
            : !managed
                ? 'Updates from the app aren\'t set up on this server yet.'
                : check.isEmpty
                    ? 'Not checked for updates yet.'
                    : behind == 0
                        ? 'Up to date'
                        : '$behind update${behind == 1 ? '' : 's'} available');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Steady version', style: context.tt.titleMedium),
      const SizedBox(height: 4),
      Text('This phone: ${kAppBuild.isEmpty ? 'development build' : 'build $kAppBuild'}'
          '${sha.isEmpty ? '' : ' · server: ${sha.length > 7 ? sha.substring(0, 7) : sha}'}',
          style: TextStyle(color: context.sc.ink2)),
      Text(line, style: TextStyle(color: behind > 0 ? context.cs.primary : context.sc.ink2, fontWeight: behind > 0 ? FontWeight.w600 : null)),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: OutlinedButton(
            onPressed: managed ? () => _open(context, ask: 'check') : null,
            child: const Text('Check for updates'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton(
            onPressed: managed ? () => _open(context, ask: 'update') : null,
            child: const Text('Update now'),
          ),
        ),
      ]),
      TextButton(onPressed: () => _open(context), child: const Text('Details and history')),
    ]);
  }
}
