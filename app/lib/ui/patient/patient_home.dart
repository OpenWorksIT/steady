// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';

import '../../app_state.dart';
import '../../models.dart';
import '../../services/api.dart';
import '../../services/push.dart';
import '../../wearable/wearable_sync.dart';
import '../settings_screen.dart';
import '../theme.dart';
import '../widgets.dart';
import 'activity_screens.dart';
import 'checkin_screen.dart';
import 'history_screen.dart';
import 'watch_screens.dart';
import '../brand.dart';

class PatientHome extends StatefulWidget {
  const PatientHome({super.key});
  @override
  State<PatientHome> createState() => _PatientHomeState();
}

class _PatientHomeState extends State<PatientHome> with WidgetsBindingObserver {
  Key _reloadKey = UniqueKey();
  UnsubscribeFunc? _unsub;
  StreamSubscription<String>? _taps;

  /// Answers waiting on the phone are tried again every two minutes while the app is open.
  Timer? _retry;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final api = AppScope.api(context);
      _taps = PushService.instance.taps.listen((_) => _refresh());
      _retry = Timer.periodic(const Duration(minutes: 2), (_) => _sendWaiting(quiet: true));
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
    _retry?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      _refresh();
      _syncWatch();
    }
  }

  /// 'missing' when the phone stopped letting Steady read watch data (often after an update).
  String _watchPerm = '';

  /// Quietly shares new watch data; failures are retried next time the app opens. Also checks
  /// the phone still lets Steady read it, and tells the practice (so they can help) if not.
  Future<void> _syncWatch() async {
    final state = AppScope.of(context);
    final api = state.api;
    if (!api.wearableConnected) return;
    try {
      await WearableSync.instance.sync(api);
    } catch (_) {}
    try {
      final perm = await WearableSync.instance.permissionStatus(api);
      if (mounted && perm != _watchPerm) setState(() => _watchPerm = perm);
      await state.reportApp(health: perm);
    } catch (_) {}
  }

  Future<void> _regrant() async {
    final api = AppScope.api(context);
    final ok = await WearableSync.instance.regrant(api);
    if (!mounted) return;
    showSnack(context, ok ? 'Thank you. Your watch data is shared again.' : 'Steady still can\'t read it. You can allow it in your phone\'s health settings.');
    await _syncWatch();
    _refresh();
  }

  void _refresh() {
    if (mounted) setState(() => _reloadKey = UniqueKey());
  }

  /// Sends answers kept on the phone. [quiet]: from the timer, so only a change is shown.
  Future<void> _sendWaiting({bool quiet = false}) async {
    final outbox = AppScope.api(context).outbox;
    if (outbox.waiting == 0) return;
    final before = outbox.waiting;
    final sent = await outbox.flush();
    if (!mounted) return;
    if (sent > 0) {
      showSnack(context, sent == 1 ? 'Sent to your psychologist.' : '$sent answers sent to your psychologist.');
      _refresh();
    } else if (!quiet && outbox.waiting == before) {
      showSnack(context, 'Steady still can\'t reach the practice. It keeps trying.');
    }
  }

  /// Sends anything waiting on the phone first; offline, the copy the phone kept last time.
  Future<PatientHomeData> _load() => AppScope.api(context).patientHome(days: 7);

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
        actions: const [SettingsButton()],
      ),
      body: BrandBackdrop(child: Loader<PatientHomeData>(
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
              _Waiting(offlineSince: d.offlineSince, onSend: () => _sendWaiting()),
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
              if (_watchPerm == 'missing') ...[
                Card(
                  color: context.sc.accentSoft,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Steady can\'t read your watch at the moment', style: context.tt.titleMedium),
                      const SizedBox(height: 4),
                      Text('This can happen after an update. Nothing is lost: allow it again and Steady catches up.',
                          style: context.tt.bodyMedium?.copyWith(color: context.sc.ink2)),
                      const SizedBox(height: 10),
                      FilledButton(onPressed: _regrant, child: const Text('Allow again')),
                    ]),
                  ),
                ),
                const SizedBox(height: 10),
              ],
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

/// Answers kept on this phone, and whether the practice can be reached. Nothing when all is sent.
class _Waiting extends StatelessWidget {
  final DateTime? offlineSince;
  final Future<void> Function() onSend;
  const _Waiting({required this.offlineSince, required this.onSend});

  @override
  Widget build(BuildContext context) {
    final outbox = AppScope.api(context).outbox;
    return ListenableBuilder(
      listenable: outbox,
      builder: (context, _) {
        final n = outbox.waiting;
        final refused = outbox.refused;
        if (offlineSince == null && n == 0 && refused.isEmpty) return const SizedBox.shrink();
        final small = context.tt.bodyMedium?.copyWith(color: context.sc.ink2);
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (offlineSince != null || n > 0)
              Card(
                color: context.sc.accentSoft,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Icon(Icons.schedule_send_outlined, color: context.sc.ink2),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                            n == 0 ? 'Steady can\'t reach the practice right now' : n == 1 ? '1 answer waiting to send' : '$n answers waiting to send',
                            style: context.tt.titleMedium),
                      ),
                    ]),
                    const SizedBox(height: 4),
                    Text(
                      offlineSince != null
                          ? 'You can still check in and do what\'s waiting. Your answers are kept on this phone and sent as soon as Steady can reach the practice. '
                              'This screen is from ${relTime(offlineSince)}.'
                          : 'They\'re kept on this phone and sent as soon as Steady can reach the practice.',
                      style: small,
                    ),
                    if (n > 0) ...[
                      const SizedBox(height: 10),
                      BusyButton(label: 'Send now', onPressed: onSend),
                    ],
                  ]),
                ),
              ),
            for (final r in refused)
              Card(
                color: context.sc.warnSoft,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${r.title} wasn\'t sent', style: context.tt.titleMedium),
                    const SizedBox(height: 4),
                    Text(r.message, style: small),
                    Align(alignment: Alignment.centerRight, child: TextButton(onPressed: outbox.clearRefused, child: const Text('OK'))),
                  ]),
                ),
              ),
          ]),
        );
      },
    );
  }
}
