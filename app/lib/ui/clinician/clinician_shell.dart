// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';

import '../../app_state.dart';
import '../../models.dart';
import '../../services/api.dart';
import '../../services/push.dart';
import '../community/community_rules.dart';
import '../community/community_tab.dart';
import '../widgets.dart';
import 'alerts_screen.dart';
import 'patients_screen.dart';

/// Shared refresh signal so a notification can refresh whichever tab is showing.
class ClinicianBus extends ChangeNotifier {
  int unread = 0;
  void changed() => notifyListeners();
}

/// The psychologist's tabs: Patients, Alerts (with the unread count) and, when the practice's
/// server has it, Community. The library and the practice's own business (its people, audit
/// report, feedback and operator agreement) are under Settings > Practice, so the bar stays short.
List<NavigationDestination> clinicianTabs({required int unread, required bool community}) => [
      const NavigationDestination(icon: Icon(Icons.people_outline), selectedIcon: Icon(Icons.people), label: 'Patients'),
      NavigationDestination(
        icon: Badge(
          isLabelVisible: unread > 0,
          label: Text('$unread'),
          child: const Icon(Icons.notifications_none),
        ),
        selectedIcon: const Icon(Icons.notifications),
        label: 'Alerts',
      ),
      if (community) const NavigationDestination(icon: Icon(Icons.forum_outlined), selectedIcon: Icon(Icons.forum), label: 'Community'),
    ];

class ClinicianShell extends StatefulWidget {
  const ClinicianShell({super.key});
  @override
  State<ClinicianShell> createState() => _ClinicianShellState();
}

class _ClinicianShellState extends State<ClinicianShell> with WidgetsBindingObserver {
  int _tab = 0;
  final _bus = ClinicianBus();
  UnsubscribeFunc? _unsub;
  StreamSubscription<String>? _taps;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final api = AppScope.api(context);
      _taps = PushService.instance.taps.listen((_) {
        setState(() => _tab = 1);
        _refreshUnread();
      });
      await _refreshUnread();
      try {
        _unsub = await api.watchNotifications((n) {
          if (!mounted) return;
          _bus.unread++;
          _bus.changed();
          setState(() {});
          _showBanner(n);
        });
      } catch (_) {/* realtime is a nicety; pull-to-refresh still works */}
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unsub?.call();
    _taps?.cancel();
    _bus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      _refreshUnread();
      _bus.changed();
    }
  }

  Future<void> _refreshUnread() async {
    try {
      final list = await AppScope.api(context).notifications();
      _bus.unread = list.where((n) => !n.read).length;
      if (mounted) setState(() {});
    } catch (_) {}
  }

  void _showBanner(AppNotification n) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(n.body.isEmpty ? n.title : '${n.title}\n${n.body}'),
        action: SnackBarAction(label: 'View', onPressed: () => setState(() => _tab = 1)),
      ));
  }

  @override
  Widget build(BuildContext context) {
    // the Steady community, when this practice's server is set up for it (its own tab, opened
    // inside Steady only)
    final forum = AppScope.of(context).config.communityUrl;
    final community = forum.isNotEmpty && communityTabHere(forum);
    // in the order of clinicianTabs
    final pages = [
      PatientsScreen(bus: _bus),
      AlertsScreen(bus: _bus, onRead: _refreshUnread),
      if (community) CommunityTab(active: _tab == 2),
    ];
    return Scaffold(
      body: IndexedStack(index: _tab, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) {
          setState(() => _tab = i);
          if (i == 1) _refreshUnread();
        },
        destinations: clinicianTabs(unread: _bus.unread, community: community),
      ),
    );
  }
}

/// Helper for screens that should reload when the bus signals.
mixin BusReload<T extends StatefulWidget> on State<T> {
  Key reloadKey = UniqueKey();
  ClinicianBus get bus;
  void _onBus() {
    if (mounted) setState(() => reloadKey = UniqueKey());
  }

  void listenToBus() => bus.addListener(_onBus);
  void stopListening() => bus.removeListener(_onBus);
  void reloadNow() => _onBus();
}

/// Shows an error snack for failed actions.
Future<void> guarded(BuildContext context, Future<void> Function() fn, {String? done}) async {
  try {
    await fn();
    if (done != null && context.mounted) showSnack(context, done);
  } catch (e) {
    if (context.mounted) showSnack(context, errorText(e));
  }
}
