// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Settings > Practice: the library and the practice's own business, out of the bottom bar so a
// psychologist's tabs stay Patients, Alerts and Community. Each row keeps the access it had before
// it moved here (the server checks too). Patients have no Practice.
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../services/api.dart';
import '../clinician/feedback_inbox_screen.dart';
import '../clinician/library_screen.dart';
import '../settings_screen.dart' show SettingsLink;
import '../theme.dart';
import 'audit_screen.dart';
import 'community_people_screen.dart';
import 'operator_agreement_screen.dart';
import 'people_screen.dart';

/// One row of Settings > Practice.
class PracticeItem {
  final IconData icon;
  final String title, subtitle;
  final Widget Function() open;
  const PracticeItem(this.icon, this.title, this.subtitle, this.open);
}

/// What Settings > Practice holds for this account, in order; empty for patients.
List<PracticeItem> practiceItems(Api api, {bool community = false}) => [
      // every psychologist sends from the library, not only the master clinician
      if (api.role == 'clinician')
        PracticeItem(Icons.menu_book_outlined, 'Library', 'Questionnaires and exercises to send, and daily words', () => const LibraryScreen()),
      // the practice admin has the people as their first screen already
      if (api.isMaster)
        PracticeItem(Icons.groups_outlined, 'People', "Patients and staff: who's set up, invites, passwords and access", () => const PeopleScreen()),
      if (api.isManager) PracticeItem(Icons.policy_outlined, 'Audit report', 'Who opened or changed what', () => const AuditScreen()),
      // which staff are in Steady Community, where this server has one
      if (api.isMaster && community)
        PracticeItem(Icons.forum_outlined, 'Community', 'Who from the practice is in Steady Community', () => const CommunityPeopleScreen()),
      // OpenWorks support reads the full reports on their own first screen
      if (api.isStaff && !api.isSupport)
        PracticeItem(Icons.feedback_outlined, 'Feedback tickets', 'What the practice raised with the Feedback button, and where it stands',
            () => const FeedbackInboxScreen()),
      if (api.isManager || api.isSupport)
        PracticeItem(Icons.description_outlined, 'Operator agreement', 'What the practice signed with OpenWorks IT',
            () => const OperatorAgreementCopyScreen()),
    ];

/// "Library, people, audit report, feedback tickets and operator agreement": what's in it for you.
String practiceSummary(List<PracticeItem> items) {
  final names = [for (final (i, p) in items.indexed) i == 0 ? p.title : p.title.toLowerCase()];
  if (names.length < 2) return names.join();
  return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}

class PracticeScreen extends StatelessWidget {
  const PracticeScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Practice')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 28), children: [
          Text(state.config.practiceName, style: context.tt.titleLarge),
          const SizedBox(height: 8),
          for (final p in practiceItems(state.api, community: state.config.communityUrl.isNotEmpty)) SettingsLink(icon: p.icon, title: p.title, subtitle: p.subtitle, open: p.open),
        ]),
      ),
    );
  }
}
