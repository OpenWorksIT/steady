// Steady - between-session check-ins for a psychology practice.
// Copyright (C) 2026 OpenWorks IT (Pty) Ltd
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU Affero General Public License as published by the Free Software Foundation,
// either version 3 of the License, or (at your option) any later version.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_state.dart';
import 'feedback/feedback.dart';
import 'feedback/trail.dart';
import 'services/api.dart';
import 'services/push.dart';
import 'ui/auth/change_password_screen.dart';
import 'ui/auth/privacy_notice_screen.dart';
import 'ui/auth/screen_lock.dart';
import 'ui/auth/server_screen.dart';
import 'ui/auth/sign_in_screen.dart';
import 'ui/auth/two_step_screen.dart';
import 'ui/clinician/clinician_shell.dart';
import 'ui/patient/daily_flow.dart';
import 'ui/practice/admin_shell.dart';
import 'ui/practice/support_shell.dart';
import 'ui/calm.dart';
import 'ui/theme.dart';
import 'ui/update_notice.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  startTrailErrorHooks();
  final api = await Api.create();
  // Must run before runApp: UnifiedPush delivers background messages by starting main().
  await PushService.instance.init(api);
  final state = AppState(api);
  // "confirm it's you" before sensitive actions: asked over whatever screen is open
  api.onConfirmNeeded = () async {
    final c = SteadyApp.navigatorKey.currentContext;
    return c != null && c.mounted && await confirmItsYou(c, api);
  };
  await state.loadLocal();
  runApp(AppScope(state: state, child: const SteadyApp()));
  await state.start();
}

class SteadyApp extends StatelessWidget {
  const SteadyApp({super.key});
  static final navigatorKey = GlobalKey<NavigatorState>();
  @override
  Widget build(BuildContext context) {
    // patients get slow, calm transitions everywhere (ui/calm.dart); staff keep the quick ones
    final patient = AppScope.of(context).isPatient;
    ThemeData theme(Brightness b) => patient ? withCalmTransitions(buildTheme(b)) : buildTheme(b);
    return MaterialApp(
        title: 'Steady',
        debugShowCheckedModeBanner: false,
        theme: theme(Brightness.light),
        darkTheme: theme(Brightness.dark),
        navigatorKey: navigatorKey,
        // screens opened go into the feedback trail; staff get the Feedback button
        navigatorObservers: [TrailObserver()],
        // staff phones: the screen lock covers every screen, not only the first
        builder: (context, child) =>
            _SystemBarSpace(child: StaffLock(child: FeedbackLayer(navigatorKey: navigatorKey, child: child ?? const SizedBox()))),
        home: const UpdateNudge(child: RootGate()),
      );
  }
}

/// Picks the first screen from who is signed in, and switches when that changes.
class RootGate extends StatelessWidget {
  const RootGate({super.key});
  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    if (!state.privacyAcknowledged) return const PrivacyNoticeScreen();
    if (!state.api.hasServer) return const ServerScreen();
    if (!state.signedIn) return const SignInScreen();
    // after a reset: a temporary password does nothing until it's replaced
    if (state.api.mustChangePassword) return const ChangePasswordScreen(forced: true);
    if (state.needsTwoStepSetup) return const TwoStepSetupScreen(forced: true);
    if (state.isClinician) return const ClinicianShell();
    if (state.isAdmin) return const AdminShell();
    if (state.isSupport) return const SupportShell();
    if (state.isPatient) return const PatientGate();
    return const SignInScreen(message: "This account can't use the app. Ask the practice to check its role.");
  }
}

/// On Android the system's navigation buttons (or gesture bar) get their own strip at the bottom,
/// so nothing in the app sits underneath them: on some phones (Samsung, three-button navigation)
/// they covered the crisis numbers at the bottom of patient screens.
class _SystemBarSpace extends StatelessWidget {
  final Widget child;
  const _SystemBarSpace({required this.child});
  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return child;
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(top: false, left: false, right: false, child: child),
    );
  }
}
