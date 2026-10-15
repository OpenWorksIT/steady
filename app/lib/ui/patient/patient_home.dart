// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';

import '../../app_state.dart';
import '../../models.dart';
import '../../services/push.dart';
import '../../wearable/wearable_sync.dart';
import '../settings_sheet.dart';
import '../theme.dart';
import '../widgets.dart';
import 'activity_screens.dart';
import 'checkin_screen.dart';
import 'history_screen.dart';
import 'watch_screens.dart';
import '../brand.dart';

class _HomeData {
  final List<Assignment> pending;
  final List<Checkin> recent;
  final List<Instrument> exercises;
  _HomeData(this.pending, this.recent, this.exercises);
}

class PatientHome extends StatefulWidget {
  const PatientHome({super.key});
  @override
  State<PatientHome> createState() => _PatientHomeState();
}

class _PatientHomeState extends State<PatientHome> with WidgetsBindingObserver {
  Key _reloadKey = UniqueKey();
  UnsubscribeFunc? _unsub;
  StreamSubscription<String>? _taps;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final api = AppScope.api(context);
      _taps = PushService.instance.taps.listen((_) => _refresh());
      _syncWatch();
      try {
        _unsub = await api.watchNotifications((n) {
          if (!mounted) return;
          showSnack(context, n.body.isEmpty ? n.title : '${n.title}: ${n.body}');
          _refresh();
        });
      } catch (_) {/* realtime is a nicety */}
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unsub?.call();
    _taps?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      _refresh();
      _syncWatch();
    }
  }

  /// Quietly shares new watch data; failures are retried next time the app opens.
  Future<void> _syncWatch() async {
    final api = AppScope.api(context);
    if (!api.wearableConnected) return;
    try {
      await WearableSync.instance.sync(api);
    } catch (_) {}
  }

  void _refresh() {
    if (mounted) setState(() => _reloadKey = UniqueKey());
  }

  Future<_HomeData> _load() async {
    final api = AppScope.api(context);
    final results = await Future.wait([api.myPending(), api.myCheckins(days: 7), api.instruments()]);
    final instruments = results[2] as List<Instrument>;
    return _HomeData(
      results[0] as List<Assignment>,
      results[1] as List<Checkin>,
      instruments.where((i) => !i.isQuestionnaire && i.sendable).toList(),
    );
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final first = state.api.myName.split(' ').first;
    final hr = DateTime.now().hour;
    final hello = hr < 12 ? 'Good morning' : hr < 17 ? 'Good afternoon' : 'Good evening';
    return Scaffold(
      appBar: AppBar(
        title: BrandedTitle(Text(state.config.practiceName,
            overflow: TextOverflow.ellipsis, style: context.tt.labelLarge?.copyWith(color: context.sc.ink2, letterSpacing: 0.6))),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => showSettingsSheet(context),
          ),
        ],
      ),
      body: BrandBackdrop(child: Loader<_HomeData>(
        key: _reloadKey,
        load: _load,
        builder: (context, d, reload) {
          final today = DateTime.now();
          final checkedToday = d.recent.where((c) =>
              c.created.year == today.year && c.created.month == today.month && c.created.day == today.day);
          return ListView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
            children: [
              Text('$hello, $first.', style: context.tt.headlineSmall),
              const SizedBox(height: 16),
              if (checkedToday.isEmpty)
                Card(
                  color: context.cs.primary,
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('How are you today?', style: context.tt.titleLarge?.copyWith(color: context.cs.onPrimary, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text('Four quick questions and a few words. About a minute.',
                          style: TextStyle(color: context.cs.onPrimary.withValues(alpha: 0.85))),
                      const SizedBox(height: 14),
                      FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: context.cs.onPrimary, foregroundColor: context.cs.primary),
                        onPressed: () => _open(const CheckinScreen()),
                        child: const Text('Start check-in'),
                      ),
                    ]),
                  ),
                )
              else
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        const Glyph(Icons.check, calm: true),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('Checked in today', style: context.tt.titleMedium),
                            Text('${relTime(checkedToday.first.created)}. You can check in again any time.',
                                style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
                          ]),
                        ),
                      ]),
                      const SizedBox(height: 10),
                      OutlinedButton(onPressed: () => _open(const CheckinScreen()), child: const Text('Check in again')),
                    ]),
                  ),
                ),
              const SizedBox(height: 10),
              WatchCard(onChanged: _refresh),
              const SizedBox(height: 12),
              SectionHeader('From your psychologist', trailing: d.pending.isEmpty ? null : '${d.pending.length} to do'),
              if (d.pending.isEmpty)
                Text('Nothing waiting. Anything your psychologist sends will show up here.',
                    style: context.tt.bodyMedium?.copyWith(color: context.sc.ink2))
              else
                for (final a in d.pending)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _Tile(
                      icon: iconFor(a.instrument),
                      calm: !(a.instrument?.isQuestionnaire ?? true),
                      title: a.name,
                      lines: [if (a.note.isNotEmpty) a.note else a.instrument?.summary ?? '', 'Sent ${relTime(a.created)}'],
                      onTap: a.instrument == null ? null : () => _open(activityScreenFor(a.instrument!, assignmentId: a.id)),
                    ),
                  ),
              const SizedBox(height: 8),
              SectionHeader('Your week', trailing: null),
              _Week(d.recent),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(onPressed: () => _open(const HistoryScreen()), child: const Text('See your check-ins')),
              ),
              if (d.exercises.isNotEmpty) ...[
                const SectionHeader('Whenever you need it'),
                for (final i in d.exercises)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _Tile(
                      icon: iconFor(i),
                      calm: true,
                      title: i.name,
                      lines: [i.summary],
                      onTap: () => _open(activityScreenFor(i)),
                    ),
                  ),
              ],
              const SizedBox(height: 12),
              const CrisisFooter(),
            ],
          );
        },
      )),
    );
  }
}

class _Tile extends StatelessWidget {
  final IconData icon;
  final bool calm;
  final String title;
  final List<String> lines;
  final VoidCallback? onTap;
  const _Tile({required this.icon, required this.calm, required this.title, required this.lines, this.onTap});
  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Glyph(icon, calm: calm),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: context.tt.titleMedium),
                  for (final l in lines.where((l) => l.isNotEmpty))
                    Text(l, style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
                ]),
              ),
              Icon(Icons.chevron_right, color: context.sc.ink3),
            ]),
          ),
        ),
      );
}

class _Week extends StatelessWidget {
  final List<Checkin> recent;
  const _Week(this.recent);
  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    const letters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    return Semantics(
      label: 'Mood over the last 7 days',
      child: Row(children: [
        for (var i = 6; i >= 0; i--)
          Expanded(child: Builder(builder: (context) {
            final day = DateTime(today.year, today.month, today.day).subtract(Duration(days: i));
            final hits = recent.where((c) => c.created.year == day.year && c.created.month == day.month && c.created.day == day.day).toList();
            final mood = hits.isEmpty ? 0 : (hits.map((c) => c.mood).reduce((a, b) => a + b) / hits.length).round();
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Column(children: [
                Tooltip(
                  message: mood == 0 ? 'No check-in' : 'Mood $mood of 5',
                  child: Container(
                    height: 30,
                    decoration: BoxDecoration(
                      color: mood == 0 ? context.sc.line : context.sc.moodScale[mood - 1],
                      borderRadius: BorderRadius.circular(9),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(letters[day.weekday - 1], style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
              ]),
            );
          })),
      ]),
    );
  }
}
