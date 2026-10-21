// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Before Steady is in the app stores, new Android builds are served by the practice's own
// server. When this copy is older than the one there, offer the download.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../build_info.dart';
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
  final url = Uri.parse('$base${state.config.apkPath.isEmpty ? '/download/steady.apk' : state.config.apkPath}');
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

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    if (appUpdateAvailable(state) && _offered != state.config.appBuild) {
      _offered = state.config.appBuild;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
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
          ),
        );
      });
    }
    return widget.child;
  }
}
