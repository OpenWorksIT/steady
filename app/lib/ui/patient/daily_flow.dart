// SPDX-License-Identifier: AGPL-3.0-or-later
//
// How the patient side opens, every time: a slow, calm sequence rather than a dashboard:
//   1. a quiet screen with a few words and a breathing circle; tapping it starts
//   2. the check-in, if there hasn't been one today, then
//   3. anything the psychologist has sent, one at a time, then
//   4. a short thank-you, fading into the usual home screen (straight there if there was nothing to do).
// A breathing glow runs behind every step and paces the transitions. Each step can be skipped;
// tapping the circle or skipping it also refreshes the watch upload.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_state.dart';
import '../../content/daily_words.dart';
import '../../models.dart';
import '../../wearable/wearable_sync.dart';
import '../brand.dart';
import '../calm.dart';
import '../theme.dart';
import '../widgets.dart';
import 'activity_screens.dart';
import 'checkin_screen.dart';
import 'patient_home.dart';

const _inhale = 4.0, _exhale = 6.0; // seconds
const _cycle = Duration(milliseconds: 10000);

/// Every time the app is opened: the calm start first, then the check-in or anything the
/// psychologist sent if needed, then the home screen. Coming back after a short trip to
/// another app (under [_away]) returns to where the patient was.
class PatientGate extends StatefulWidget {
  const PatientGate({super.key});
  @override
  State<PatientGate> createState() => _PatientGateState();
}

class _PatientGateState extends State<PatientGate> with WidgetsBindingObserver {
  static const _away = Duration(minutes: 5);
  bool _showFlow = true;
  int _flowRun = 0;
  DateTime? _leftAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden) {
      _leftAt ??= DateTime.now();
    } else if (s == AppLifecycleState.resumed) {
      final left = _leftAt;
      _leftAt = null;
      if (left != null && DateTime.now().difference(left) >= _away && !_showFlow && mounted) {
        setState(() {
          _flowRun++;
          _showFlow = true;
        });
      }
    }
  }

  void _finished() {
    if (mounted) setState(() => _showFlow = false);
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return AnimatedSwitcher(
      duration: Duration(milliseconds: reduce ? 200 : 1800),
      switchInCurve: Curves.easeInOutCubic,
      switchOutCurve: Curves.easeInOutCubic,
      child: _showFlow
          ? DailyFlow(key: ValueKey('flow$_flowRun'), onFinished: () async => _finished())
          : const PatientHome(key: ValueKey('home')),
    );
  }
}

enum _Step { breathe, checkin, activity, thanks }

class DailyFlow extends StatefulWidget {
  final Future<void> Function() onFinished;
  const DailyFlow({required this.onFinished, super.key});
  @override
  State<DailyFlow> createState() => _DailyFlowState();
}

class _DailyFlowState extends State<DailyFlow> with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(vsync: this, duration: _cycle)..repeat();
  _Step _step = _Step.breathe;
  List<Assignment> _pending = const [];
  int _index = 0;
  bool _checkedInToday = false;
  String _words = wordsForToday(const []);
  Timer? _thanks;

  final _prepared = Completer<void>();

  @override
  void initState() {
    super.initState();
    // notices (such as a new app version) wait until the calm start is over (calm.dart)
    calmStartActive.value = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepare().whenComplete(() {
          if (!_prepared.isCompleted) _prepared.complete();
        }));
  }

  @override
  void dispose() {
    calmStartActive.value = false;
    _thanks?.cancel();
    _breath.dispose();
    super.dispose();
  }

  /// Quietly, in the background: the psychologist's own words, what's waiting, today's check-in.
  Future<void> _prepare() async {
    final api = AppScope.api(context);
    try {
      final q = await api.quotes();
      if (mounted) setState(() => _words = wordsForToday(q.where((x) => x.active).map((x) => x.text).toList()));
    } catch (_) {}
    try {
      final r = await Future.wait([api.myPending(), api.myCheckins(days: 1)]);
      final today = DateTime.now();
      if (!mounted) return;
      setState(() {
        _pending = (r[0] as List<Assignment>).where((a) => a.instrument != null).toList();
        _checkedInToday = (r[1] as List<Checkin>)
            .any((c) => c.created.year == today.year && c.created.month == today.month && c.created.day == today.day);
      });
    } catch (_) {/* the home screen shows everything anyway */}
  }

  void _go(_Step s) {
    if (!mounted) return;
    setState(() => _step = s);
    if (s == _Step.thanks) {
      _thanks?.cancel();
      _thanks = Timer(const Duration(milliseconds: 3200), widget.onFinished);
    }
  }

  void _afterCheckin() => _go(_pending.isEmpty ? _Step.thanks : _Step.activity);

  bool _leaving = false;

  Future<void> _tapCircle() async {
    if (_leaving) return;
    _leaving = true;
    HapticFeedback.lightImpact();
    final api = AppScope.api(context);
    if (api.wearableConnected) unawaited(WearableSync.instance.sync(api).catchError((_) => null));
    // know whether there's a check-in or anything waiting before choosing the next step
    await _prepared.future.timeout(const Duration(seconds: 6), onTimeout: () {});
    if (!mounted) return;
    if (!_checkedInToday) {
      _go(_Step.checkin);
    } else if (_pending.isNotEmpty) {
      _go(_Step.activity);
    } else {
      widget.onFinished(); // checked in already and nothing waiting: straight to home
    }
  }

  Future<void> _begin(Assignment a) async {
    await Navigator.of(context).push(PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 900),
      reverseTransitionDuration: const Duration(milliseconds: 900),
      pageBuilder: (_, _, _) => activityScreenFor(a.instrument!, assignmentId: a.id),
      transitionsBuilder: (_, anim, _, child) => FadeTransition(opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOutCubic), child: child),
    ));
    if (!mounted) return;
    if (_index + 1 < _pending.length) {
      setState(() => _index++);
    } else {
      _go(_Step.thanks);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final Widget body = switch (_step) {
      _Step.breathe => _BreatheStep(
          key: const ValueKey('breathe'),
          breath: _breath,
          words: _words,
          practice: AppScope.of(context).config.practiceName,
          checkedIn: _checkedInToday,
          onTap: _tapCircle,
        ),
      _Step.checkin => _CheckinStep(key: const ValueKey('checkin'), breath: _breath, onSent: () async => _afterCheckin()),
      _Step.activity => _ActivityStep(
          key: ValueKey('activity$_index'),
          assignment: _pending[_index],
          position: _index + 1,
          count: _pending.length,
          onBegin: () => _begin(_pending[_index]),
        ),
      _Step.thanks => _ThanksStep(key: const ValueKey('thanks'), breath: _breath, onTap: widget.onFinished),
    };
    final (String?, VoidCallback?) skip = switch (_step) {
      _Step.breathe => ('Skip', () => _tapCircle()),
      _Step.checkin => ('Skip the check-in', () => _go(_pending.isEmpty ? _Step.thanks : _Step.activity)),
      _Step.activity => ('Later', () => _go(_Step.thanks)),
      _Step.thanks => (null, null),
    };
    return Scaffold(
      body: _CalmBackdrop(
        breath: _breath,
        child: SafeArea(
          child: Column(children: [
            Expanded(
              child: AnimatedSwitcher(
                duration: Duration(milliseconds: reduce ? 200 : 1600),
                switchInCurve: const Interval(0.35, 1, curve: Curves.easeInOutCubic),
                switchOutCurve: Curves.easeInOutCubic,
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: ScaleTransition(scale: Tween(begin: 0.985, end: 1.0).animate(anim), child: child),
                ),
                child: body,
              ),
            ),
            SizedBox(
              height: 44,
              child: AnimatedOpacity(
                opacity: skip.$1 == null ? 0 : 1,
                duration: const Duration(milliseconds: 800),
                child: skip.$1 == null
                    ? const SizedBox()
                    : TextButton(
                        onPressed: skip.$2,
                        style: TextButton.styleFrom(foregroundColor: context.sc.ink3, textStyle: context.tt.bodySmall),
                        child: Text(skip.$1!),
                      ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// 0..1: how full the lungs are, breathing in for 4 s and out for 6 s.
double _fullness(double t) {
  final s = t * (_inhale + _exhale);
  if (s < _inhale) return Curves.easeInOutSine.transform(s / _inhale);
  return 1 - Curves.easeInOutSine.transform((s - _inhale) / _exhale);
}

bool _breathingIn(double t) => t * (_inhale + _exhale) < _inhale;

/// A soft glow that swells and settles with the breath, behind every step of the daily start.
class _CalmBackdrop extends StatelessWidget {
  final Animation<double> breath;
  final Widget child;
  const _CalmBackdrop({required this.breath, required this.child});
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = Theme.of(context).scaffoldBackgroundColor;
    final glow = Color.lerp(context.sc.calmSoft, context.sc.accentSoft, 0.5)!;
    return AnimatedBuilder(
      animation: breath,
      builder: (context, kid) {
        final f = _fullness(breath.value);
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0, -0.15),
              radius: 0.75 + 0.35 * f,
              colors: [glow.withValues(alpha: dark ? 0.55 + 0.25 * f : 0.75 + 0.25 * f), base],
            ),
          ),
          child: kid,
        );
      },
      child: Stack(fit: StackFit.expand, children: [
        Positioned(
          right: -70,
          bottom: -50,
          child: IgnorePointer(
            child: Opacity(
              opacity: dark ? 0.08 : 0.05,
              child: const PracticeMark(width: 320),
            ),
          ),
        ),
        child,
      ]),
    );
  }
}

class _BreatheStep extends StatelessWidget {
  final Animation<double> breath;
  final String words, practice;
  final bool checkedIn;
  final VoidCallback onTap;
  const _BreatheStep({required this.breath, required this.words, required this.practice, required this.checkedIn, required this.onTap, super.key});

  @override
  Widget build(BuildContext context) {
    final first = AppScope.api(context).myName.split(' ').first;
    final hr = DateTime.now().hour;
    final hello = hr < 12 ? 'Good morning' : hr < 17 ? 'Good afternoon' : 'Good evening';
    return LayoutBuilder(builder: (context, c) {
      final maxCircle = math.min(260.0, math.min(c.maxWidth * 0.62, c.maxHeight * 0.36));
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(children: [
          const SizedBox(height: 22),
          const Opacity(opacity: 0.85, child: PracticeMark(size: 44)),
          const Spacer(flex: 2),
          _SlowIn(
            delay: 300,
            child: Text('$hello${first.isEmpty ? '' : ', $first'}.', textAlign: TextAlign.center, style: context.tt.titleMedium?.copyWith(color: context.sc.ink2)),
          ),
          const SizedBox(height: 18),
          _SlowIn(
            delay: 900,
            child: Text(
              words,
              textAlign: TextAlign.center,
              style: context.tt.headlineSmall?.copyWith(height: 1.35, fontWeight: FontWeight.w400),
            ),
          ),
          const Spacer(flex: 2),
          _SlowIn(
            delay: 1800,
            child: Semantics(
              button: true,
              label: checkedIn ? 'Continue' : 'Start your check-in',
              child: GestureDetector(
                onTap: onTap,
                child: AnimatedBuilder(
                  animation: breath,
                  builder: (context, _) {
                    final f = _fullness(breath.value);
                    final size = maxCircle * (0.55 + 0.45 * f);
                    return SizedBox(
                      width: maxCircle,
                      height: maxCircle,
                      child: Center(
                        child: Container(
                          width: size,
                          height: size,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: context.cs.primary.withValues(alpha: 0.16 + 0.14 * f),
                            border: Border.all(color: context.cs.primary.withValues(alpha: 0.35 + 0.3 * f), width: 2),
                            boxShadow: [BoxShadow(color: context.cs.primary.withValues(alpha: 0.12 * f), blurRadius: 40 * f, spreadRadius: 6 * f)],
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            _breathingIn(breath.value) ? 'Breathe in' : 'Breathe out',
                            style: context.tt.titleMedium?.copyWith(color: context.cs.primary, letterSpacing: 0.6),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          _SlowIn(
            delay: 2600,
            child: Text(
              checkedIn ? 'Breathe with the circle. Tap it when you\'re ready to carry on.' : 'Breathe with the circle for a moment. Tap it when you\'re ready to check in.',
              textAlign: TextAlign.center,
              style: context.tt.bodyMedium?.copyWith(color: context.sc.ink2),
            ),
          ),
          const Spacer(),
        ]),
      );
    });
  }
}

class _CheckinStep extends StatelessWidget {
  final Animation<double> breath;
  final Future<void> Function() onSent;
  const _CheckinStep({required this.breath, required this.onSent, super.key});
  @override
  Widget build(BuildContext context) => Column(children: [
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(children: [
            Text('How are you today?', textAlign: TextAlign.center, style: context.tt.headlineSmall),
            const SizedBox(height: 6),
            Text('Take your time. There are no wrong answers.', textAlign: TextAlign.center, style: TextStyle(color: context.sc.ink2)),
          ]),
        ),
        const SizedBox(height: 12),
        Expanded(child: CheckinForm(onSent: onSent, sendLabel: 'Send')),
      ]);
}

class _ActivityStep extends StatelessWidget {
  final Assignment assignment;
  final int position, count;
  final VoidCallback onBegin;
  const _ActivityStep({required this.assignment, required this.position, required this.count, required this.onBegin, super.key});
  @override
  Widget build(BuildContext context) {
    final a = assignment;
    final kind = (a.instrument?.isQuestionnaire ?? true) ? 'a few questions' : 'an exercise';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(children: [
        const Spacer(flex: 2),
        if (count > 1) Text('$position of $count', style: context.tt.labelMedium?.copyWith(color: context.sc.ink3)),
        const SizedBox(height: 10),
        Text('Your psychologist sent you $kind', textAlign: TextAlign.center, style: context.tt.titleMedium?.copyWith(color: context.sc.ink2)),
        const SizedBox(height: 14),
        Glyph(iconFor(a.instrument), calm: !(a.instrument?.isQuestionnaire ?? true)),
        const SizedBox(height: 14),
        Text(a.name, textAlign: TextAlign.center, style: context.tt.headlineSmall),
        if (a.note.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text('"${a.note}"', textAlign: TextAlign.center, style: context.tt.bodyLarge?.copyWith(fontStyle: FontStyle.italic, color: context.sc.ink2)),
        ] else if ((a.instrument?.summary ?? '').isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(a.instrument!.summary, textAlign: TextAlign.center, style: context.tt.bodyMedium?.copyWith(color: context.sc.ink2)),
        ],
        const Spacer(),
        FilledButton(onPressed: onBegin, child: const Text('Begin')),
        const Spacer(),
      ]),
    );
  }
}

class _ThanksStep extends StatelessWidget {
  final Animation<double> breath;
  final Future<void> Function() onTap;
  const _ThanksStep({required this.breath, required this.onTap, super.key});
  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.spa_outlined, size: 44, color: context.sc.calm),
            const SizedBox(height: 16),
            Text('Thank you', style: context.tt.headlineSmall),
            const SizedBox(height: 8),
            Text('Taking a moment for yourself matters.', textAlign: TextAlign.center, style: context.tt.bodyLarge?.copyWith(color: context.sc.ink2)),
          ]),
        ),
      );
}

/// Fades and lifts its child in, slowly, after [delay] milliseconds.
class _SlowIn extends StatelessWidget {
  final int delay;
  final Widget child;
  const _SlowIn({required this.delay, required this.child});
  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduce) return child;
    final total = delay + 1400;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delay / total, 1, curve: Curves.easeOutCubic),
      builder: (context, t, kid) => Opacity(opacity: t, child: Transform.translate(offset: Offset(0, 10 * (1 - t)), child: kid)),
      child: child,
    );
  }
}
