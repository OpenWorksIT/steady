// SPDX-License-Identifier: AGPL-3.0-or-later
//
// "My practice may contact me about what I share in Steady": asked when a patient joins (ticked
// to start with), right above the button that agrees; asked once of patients who joined before
// Steady asked (consent_again_screen.dart); and changeable in Settings. The practice may always
// contact its patients; this makes sure the patient agrees to being contacted about their Steady
// data in particular, and says plainly that Steady isn't watched around the clock.
//
// The wording's version is the server's CONTACT_VERSION (server/pb_hooks/lib/server.js): change
// both together.
import 'package:flutter/material.dart';

import '../theme.dart';

const contactConsentVersion = 'contact-1';

String contactConsentTitle(String practice) => 'Yes, $practice may contact me about what I share in Steady';

const contactConsentDetail = 'For example about my check-ins, answers or watch data. Steady isn\'t watched around the clock, '
    'so this doesn\'t mean they\'ll see everything straight away. I can change this in Settings.';

/// The tick box, as it sits right above an agree button.
class ContactConsentTile extends StatelessWidget {
  final String practiceName;
  final bool value;
  final ValueChanged<bool> onChanged;
  const ContactConsentTile({required this.practiceName, required this.value, required this.onChanged, super.key});

  @override
  Widget build(BuildContext context) => CheckboxListTile(
        value: value,
        onChanged: (v) => onChanged(v ?? false),
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: EdgeInsets.zero,
        title: Text(contactConsentTitle(practiceName)),
        subtitle: Text(contactConsentDetail, style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
      );
}
