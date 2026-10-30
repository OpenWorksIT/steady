// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Before Steady is in the app stores, new Android builds are served by the practice's own
// server. When this copy is older than the one there, offer the download.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../build_info.dart';
import 'calm.dart';
import 'widgets.dart';

/// True when this is the Android app and the server has a different (newer) build.
bool appUpdateAvailable(AppState state) {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
  final latest = state.config.appBuild;
  return state.config.appUpdatable && kAppBuild.isNotEmpty && latest.isNotEmpty && latest != kAppBuild;
}

/// Opens the download in the browser; Android then offers to install it.
Future<void> downloadAppUpdate(BuildContext context) async {
  final state = AppScope.of(context);
  final base = state.api.serverUrl.replaceAll(RegExp(r'/+$'), '');
  // a path on this same server only (never "//elsewhere" or "@elsewhere")
  final p = state.config.apkPath;
  final safe = RegExp(r'^/[A-Za-z0-9._/-]*$').hasMatch(p) && !p.startsWith('//') && !p.contains('..');
  final url = Uri.parse('$base${safe ? p : '/download/steady.apk'}');
  final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) showSnack(context, 'Couldn\'t open the download. Open $url in your browser.');
}

/// Shows "a new version is ready" once per app start, over whatever screen is open.
class UpdateNudge extends StatefulWidget {
  final Widget child;
  const UpdateNudge({required this.child, super.key});
  @override
  State<UpdateNudge> createState() => _UpdateNudgeState();
}

class _UpdateNudgeState extends State<UpdateNudge> {
  static String? _offered;
  VoidCallback? _waitForCalm;

  @override
  void dispose() {
    if (_waitForCalm != null) calmStartActive.removeListener(_waitForCalm!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    if (appUpdateAvailable(state) && _offered != state.config.appBuild) {
      _offered = state.config.appBuild;
      final patient = state.isPatient;
      WidgetsBinding.instance.addPostFrameCallback((_) => patient ? _offerWhenCalm() : _offer(calm: false));
    }
    return widget.child;
  }

  /// Patients: never during the calm start. Once it's over, let the home screen settle, then ask.
  void _offerWhenCalm() {
    if (!mounted) return;
    if (calmStartActive.value) {
      void listener() {
        if (calmStartActive.value) return;
        calmStartActive.removeListener(listener);
        _waitForCalm = null;
        _offerWhenCalm();
      }

      _waitForCalm = listener;
      calmStartActive.addListener(listener);
      return;
    }
    Future<void>.delayed(const Duration(milliseconds: 2500), () {
      if (!mounted) return;
      // reopened in the meantime: wait for that calm start to finish too
      calmStartActive.value ? _offerWhenCalm() : _offer(calm: true);
    });
  }

  void _offer({required bool calm}) {
    if (!mounted) return;
    Widget dialog(BuildContext c) => AlertDialog(
            title: const Text('A new version of Steady'),
            content: const Text('Download it and tap Install when your phone asks. '
                'You stay signed in and nothing is lost.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c), child: const Text('Later')),
              FilledButton(
                onPressed: () {
                  Navigator.pop(c);
                  downloadAppUpdate(context);
                },
                child: const Text('Download'),
              ),
            ],
          );
    if (calm) {
      showCalmDialog<void>(context: context, builder: dialog);
    } else {
      showDialog<void>(context: context, builder: dialog);
    }
  }
}
