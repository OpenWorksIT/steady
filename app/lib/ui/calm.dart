// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Calm motion for patients. Everything a patient sees moves at the pace of the daily start's
// breathing circle: pages dissolve in slowly instead of sliding, pop-ups fade in, and nothing
// (not even "a new version is ready") interrupts the calm start itself. Psychologists and
// administrators keep the normal, quicker transitions.
import 'package:flutter/material.dart';

/// How long a patient's page takes to appear, and to leave.
const calmIn = Duration(milliseconds: 1100);
const calmOut = Duration(milliseconds: 900);

/// Pop-ups and sheets.
const calmDialogIn = Duration(milliseconds: 900);
const calmDialogOut = Duration(milliseconds: 600);

/// True while the daily calm start is on screen (daily_flow.dart). Notices wait until it ends.
final calmStartActive = ValueNotifier<bool>(false);

/// True when the phone asks for reduced motion: then everything is quick and plain.
bool get _reduceMotion => WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations;

/// A slow dissolve: the new page fades in and settles from a touch smaller, the old one fades back.
class CalmPageTransitionsBuilder extends PageTransitionsBuilder {
  const CalmPageTransitionsBuilder();

  @override
  Duration get transitionDuration => _reduceMotion ? const Duration(milliseconds: 150) : calmIn;

  @override
  Duration get reverseTransitionDuration => _reduceMotion ? const Duration(milliseconds: 150) : calmOut;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final into = CurvedAnimation(parent: animation, curve: Curves.easeInOutSine);
    final away = CurvedAnimation(parent: secondaryAnimation, curve: Curves.easeInOutSine);
    return FadeTransition(
      // the page underneath dims while the next one arrives, so the change is a dissolve
      opacity: Tween<double>(begin: 1, end: 0.35).animate(away),
      child: FadeTransition(
        opacity: into,
        child: ScaleTransition(scale: Tween<double>(begin: 0.985, end: 1).animate(into), child: child),
      ),
    );
  }
}

/// The app's theme with calm page transitions on every platform (for patients).
ThemeData withCalmTransitions(ThemeData base) => base.copyWith(
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: CalmPageTransitionsBuilder(),
        TargetPlatform.iOS: CalmPageTransitionsBuilder(),
        TargetPlatform.macOS: CalmPageTransitionsBuilder(),
        TargetPlatform.linux: CalmPageTransitionsBuilder(),
        TargetPlatform.windows: CalmPageTransitionsBuilder(),
        TargetPlatform.fuchsia: CalmPageTransitionsBuilder(),
      }),
    );

/// A dialog that fades in slowly over a soft dimmed background.
Future<T?> showCalmDialog<T>({required BuildContext context, required WidgetBuilder builder, bool dismissible = true}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.32),
    transitionDuration: _reduceMotion ? const Duration(milliseconds: 150) : calmDialogIn,
    pageBuilder: (ctx, _, _) => SafeArea(child: Builder(builder: builder)),
    transitionBuilder: (ctx, animation, _, child) {
      final a = CurvedAnimation(parent: animation, curve: Curves.easeInOutSine, reverseCurve: Curves.easeInOutSine);
      return FadeTransition(
        opacity: a,
        child: ScaleTransition(scale: Tween<double>(begin: 0.97, end: 1).animate(a), child: child),
      );
    },
  );
}

/// Bottom-sheet timing for patients (null keeps the normal timing).
AnimationStyle? calmSheetStyle(bool patient) =>
    patient && !_reduceMotion ? AnimationStyle(duration: calmDialogIn, reverseDuration: calmDialogOut) : null;
