// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Community tab: the Steady community (community.steadyapp.co.za) for psychologists, opened
// inside Steady and only here, signed in as whoever is signed in to Steady. The tab asks the
// server for a short note saying who that is (Api.communitySignIn) and opens the community with
// it; OpenWorks' sign-in bridge does the rest (docs/COMMUNITY.md). Nothing is opened until the
// tab is first chosen, and choosing it again later keeps the page where it was.
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../services/api.dart';
import '../theme.dart';
import 'community_frame.dart';

class CommunityTab extends StatefulWidget {
  /// The tab is showing: the community opens the first time it does.
  final bool active;
  const CommunityTab({required this.active, super.key});
  @override
  State<CommunityTab> createState() => _CommunityTabState();
}

class _CommunityTabState extends State<CommunityTab> {
  String? _start;
  String? _error;
  bool _signedOut = false;
  bool _opening = false;
  DateTime? _openedAt;
  Key _frame = UniqueKey();

  @override
  void didUpdateWidget(CommunityTab old) {
    super.didUpdateWidget(old);
    if (widget.active && _start == null && _error == null && !_signedOut && !_opening) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _open());
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.active) WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  Future<void> _open() async {
    if (_opening || !mounted) return;
    final api = AppScope.api(context);
    setState(() {
      _opening = true;
      _error = null;
      _signedOut = false;
      _start = null; // a note works once: never open the last one again
    });
    try {
      final start = await api.communitySignIn();
      if (!mounted) return;
      setState(() {
        _start = start;
        _openedAt = DateTime.now();
        _frame = UniqueKey(); // a new frame for each sign-in
      });
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  /// A community page asked: "sign-in" (its sign-in ran out, or it was opened some other way)
  /// opens it again for whoever is in Steady, but not twice in a minute, so a browser that won't
  /// keep the community's cookies doesn't go round in circles. "signed-out": they chose to.
  void _message(String m) {
    if (m == 'signed-out') {
      setState(() => _signedOut = true);
      return;
    }
    final last = _openedAt;
    if (last == null || DateTime.now().difference(last) > const Duration(minutes: 1)) {
      _open();
    } else {
      setState(() => _error = "The community didn't open here. Try again, or use the Steady app on your phone.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final forum = AppScope.of(context).config.communityUrl;
    final start = _start;
    Widget body;
    if (_error != null || _signedOut) {
      body = _Note(
        text: _signedOut ? "You've signed out of the community." : _error!,
        action: _signedOut ? 'Open the community' : 'Try again',
        onPressed: _opening ? null : _open,
      );
    } else if (start == null || forum.isEmpty) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = CommunityFrame(key: _frame, start: start, forum: forum, onMessage: _message);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Community'),
        actions: [
          IconButton(
            tooltip: 'Open it again',
            icon: const Icon(Icons.refresh),
            onPressed: _opening ? null : _open,
          ),
        ],
      ),
      body: SafeArea(top: false, child: body),
    );
  }
}

class _Note extends StatelessWidget {
  final String text;
  final String action;
  final VoidCallback? onPressed;
  const _Note({required this.text, required this.action, required this.onPressed});
  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(text, textAlign: TextAlign.center, style: context.tt.bodyLarge),
              const SizedBox(height: 16),
              FilledButton(onPressed: onPressed, child: Text(action)),
            ]),
          ),
        ),
      );
}
