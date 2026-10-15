// Steady - between-session check-ins for a psychology practice.
// Copyright (C) 2026 OpenWorks IT (Pty) Ltd
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU Affero General Public License as published by the Free Software Foundation,
// either version 3 of the License, or (at your option) any later version.
import 'package:flutter/material.dart';

import 'app_state.dart';
import 'services/api.dart';
import 'services/push.dart';
import 'ui/auth/privacy_notice_screen.dart';
import 'ui/auth/server_screen.dart';
import 'ui/auth/sign_in_screen.dart';
import 'ui/clinician/clinician_shell.dart';
import 'ui/patient/patient_home.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final api = await Api.create();
  // Must run before runApp: UnifiedPush delivers background messages by starting main().
  await PushService.instance.init(api);
  final state = AppState(api);
  await state.loadLocal();
  runApp(AppScope(state: state, child: const SteadyApp()));
  await state.start();
}

class SteadyApp extends StatelessWidget {
  const SteadyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Steady',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: const RootGate(),
      );
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
    if (state.isClinician) return const ClinicianShell();
    if (state.isPatient) return const PatientHome();
    return const SignInScreen(message: "This account can't use the app. Ask the practice to check its role.");
  }
}
