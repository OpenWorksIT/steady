// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../community/community_rules.dart';
import '../community/community_tab.dart';
import 'people_screen.dart';

/// The practice administrator's tabs: People and, when the practice's server has it, Community
/// (where they see the Steady manual only). Without the community there is no bar: People is
/// the whole screen, as before.
List<NavigationDestination> adminTabs({required bool community}) => [
      const NavigationDestination(icon: Icon(Icons.people_outline), selectedIcon: Icon(Icons.people), label: 'People'),
      if (community) const NavigationDestination(icon: Icon(Icons.forum_outlined), selectedIcon: Icon(Icons.forum), label: 'Community'),
    ];

/// The practice administrator: the practice's people, names only, and the community's manual.
class AdminShell extends StatefulWidget {
  const AdminShell({super.key});
  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> {
  int _tab = 0;
  @override
  Widget build(BuildContext context) {
    // the Steady community, when this practice's server is set up for it (as for psychologists)
    final forum = AppScope.of(context).config.communityUrl;
    final community = forum.isNotEmpty && communityTabHere(forum);
    if (!community) return const PeopleScreen(home: true);
    // in the order of adminTabs
    return Scaffold(
      body: IndexedStack(index: _tab, children: [
        const PeopleScreen(home: true),
        CommunityTab(active: _tab == 1),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: adminTabs(community: true),
      ),
    );
  }
}
