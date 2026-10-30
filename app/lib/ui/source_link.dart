// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Who made Steady, and where its source code is: the AGPL asks that everyone who uses it over a
// network can get the source. Shown in Settings and under the sign-in form.
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../build_info.dart';
import 'theme.dart';

class SourceLink extends StatelessWidget {
  const SourceLink({super.key});

  @override
  Widget build(BuildContext context) {
    final small = context.tt.bodySmall?.copyWith(color: context.sc.ink3);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Steady is free software (AGPL-3.0): code by OpenWorks IT, clinical science by VR Clinical Psychology.', style: small),
      TextButton(
        style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 36), alignment: Alignment.centerLeft),
        onPressed: () => launchUrl(Uri.parse(kSourceUrl), mode: LaunchMode.externalApplication).catchError((_) => false),
        child: const Text('Source code'),
      ),
    ]);
  }
}
