// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../wearable/wearable_sync.dart';
import '../theme.dart';
import '../widgets.dart';

/// Home-screen card: connect a watch, or see when it last synced.
class WatchCard extends StatefulWidget {
  final VoidCallback onChanged;
  const WatchCard({required this.onChanged, super.key});
  @override
  State<WatchCard> createState() => _WatchCardState();
}

class _WatchCardState extends State<WatchCard> {
  DateTime? _last;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshLast());
  }

  Future<void> _refreshLast() async {
    final t = await WearableSync.instance.lastSync(AppScope.api(context));
    if (mounted) setState(() => _last = t);
  }

  Future<void> _sync() async {
    setState(() => _syncing = true);
    try {
      final r = await WearableSync.instance.sync(AppScope.api(context));
      if (mounted && r != null) {
        showSnack(
            context,
            r.days > 0
                ? 'Watch data shared (${r.days} days).'
                : r.everHadData
                    ? 'No new watch data yet.'
                    : '${WearableSync.instance.store?.name ?? 'Your phone'} has no watch data for Steady yet. Check that your watch\'s app shares with it, then tap Sync now.');
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Couldn\'t sync watch data. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _syncing = false);
      _refreshLast();
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = AppScope.api(context);
    if (!WearableSync.instance.supported) return const SizedBox.shrink();
    if (!api.wearableConnected) {
      return Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () async {
            final done = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const ConnectWatchScreen()));
            if (done == true) {
              widget.onChanged();
              _refreshLast();
            }
          },
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              const Glyph(Icons.watch_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Connect your watch', style: context.tt.titleMedium),
                  Text('Optional. Share heart rate, sleep and steps with your psychologist.',
                      style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
                ]),
              ),
              Icon(Icons.chevron_right, color: context.sc.ink3),
            ]),
          ),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
        child: Row(children: [
          const Glyph(Icons.watch, calm: true),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Watch data shared', style: context.tt.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              Text(_last == null ? 'Not synced yet' : 'Last synced ${relTime(_last)}',
                  style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
            ]),
          ),
          _syncing
              ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5)))
              : IconButton(tooltip: 'Sync now', onPressed: _sync, icon: const Icon(Icons.sync)),
        ]),
      ),
    );
  }
}

/// Explains what is shared and asks for agreement before connecting.
class ConnectWatchScreen extends StatefulWidget {
  const ConnectWatchScreen({super.key});
  @override
  State<ConnectWatchScreen> createState() => _ConnectWatchScreenState();
}

class _ConnectWatchScreenState extends State<ConnectWatchScreen> {
  bool _agree = false;
  String? _error;

  Future<void> _connect() async {
    setState(() => _error = null);
    final api = AppScope.api(context);
    final state = AppScope.of(context);
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final err = await WearableSync.instance.connect(api);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    state.changed();
    messenger.showSnackBar(const SnackBar(content: Text('Watch connected. Your psychologist can now see your watch data.')));
    nav.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final store = WearableSync.instance.store;
    final storeName = store?.name ?? 'your phone\'s health app';
    final practice = AppScope.of(context).config.practiceName;
    Widget bullet(String t) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('•  '),
            Expanded(child: Text(t)),
          ]),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Connect your watch')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
          children: [
            Text(
              'Steady can read what your watch saves in $storeName and share a daily summary with your psychologist. '
              'This is optional and you can stop at any time.',
              style: context.tt.bodyLarge,
            ),
            const SizedBox(height: 16),
            Text('What is shared', style: context.tt.titleMedium),
            const SizedBox(height: 6),
            bullet('Heart rate: your lowest, average and highest for each day, and your resting heart rate.'),
            bullet('Sleep: how long you slept, when, and your sleep stages.'),
            bullet('Steps for each day.'),
            bullet('Blood oxygen, if your watch measures it.'),
            const SizedBox(height: 10),
            Text('How it is used', style: context.tt.titleMedium),
            const SizedBox(height: 6),
            bullet('Only daily totals and averages leave your phone, not every reading.'),
            bullet('Up to the last 30 days are shared when you connect, then new days as you use Steady.'),
            bullet('Only your psychologist at $practice can see it. It helps them understand how you are doing between sessions and may be used, without your name, to improve care.'),
            bullet('Nobody watches this data around the clock. It does not raise alarms. If you need help, use the crisis numbers on your home screen.'),
            bullet('To stop, open Settings in Steady and tap "Stop sharing watch data". You can also remove Steady\'s access in $storeName.'),
            const SizedBox(height: 12),
            Card(
              child: CheckboxListTile(
                value: _agree,
                onChanged: (v) => setState(() => _agree = v ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('I agree to share my watch data with my psychologist as described above'),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: TextStyle(color: context.cs.error)),
            ],
            const SizedBox(height: 14),
            BusyButton(label: 'Connect', onPressed: _agree ? _connect : null),
            const SizedBox(height: 10),
            Text('Next, $storeName will ask which data Steady may read. Allow all of them for the full picture.',
                style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
          ],
        ),
      ),
    );
  }
}
