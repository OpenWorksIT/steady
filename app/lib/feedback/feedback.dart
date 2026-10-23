// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Feedback button on psychologists' and administrators' screens (never patients'): "Love this",
// "Don't like this" and "Bug found", as in Sorted. A bug report carries a screenshot of the screen
// as it was when the button was pressed, blurred so no one can be read from it unless the sender
// chooses otherwise, and the last 60 steps (trail.dart). Read in Settings > Feedback (master
// psychologist and administrators) and by OpenWorks IT with deploy/feedback.sh.
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../app_state.dart';
import '../build_info.dart';
import '../services/api.dart';
import '../ui/theme.dart';
import 'trail.dart';

/// Wraps the app: the screen area that screenshots capture, the tap trail, and the button.
class FeedbackLayer extends StatelessWidget {
  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;
  const FeedbackLayer({required this.child, required this.navigatorKey, super.key});

  static final captureKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final staff = state.signedIn && (state.isClinician || state.isAdmin) && !state.api.mustChangePassword;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Stack(children: [
      RepaintBoundary(key: captureKey, child: TrailTaps(child: child)),
      if (staff && !keyboard)
        Positioned(
          left: 6,
          bottom: 92 + MediaQuery.viewPaddingOf(context).bottom,
          child: FeedbackButton(navigatorKey: navigatorKey),
        ),
    ]);
  }
}

/// The round Feedback button. It sits above the app's navigator (in MaterialApp.builder), where
/// there is no Overlay, so it must not use a Tooltip or anything else that needs one: a Tooltip
/// there fails on hover (web) or long-press and Flutter paints an error panel over the screen.
/// The hint is drawn beside the button instead.
class FeedbackButton extends StatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;
  const FeedbackButton({required this.navigatorKey, super.key});
  @override
  State<FeedbackButton> createState() => _FeedbackButtonState();
}

class _FeedbackButtonState extends State<FeedbackButton> {
  bool _busy = false;
  bool _hover = false;

  Future<void> _open() async {
    final nav = widget.navigatorKey.currentState;
    if (nav == null || _busy) return;
    setState(() => _busy = true);
    // the moment the button was pressed: that's what the report is about
    final pressed = DateTime.now();
    final screen = Trail.screen;
    final shots = await captureScreen();
    final steps = Trail.entries;
    if (!mounted) return;
    setState(() => _busy = false);
    final ctx = nav.context;
    if (!ctx.mounted) return;
    await showModalBottomSheet<void>(
      context: ctx,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => FeedbackSheet(pressedAt: pressed, screen: screen, shots: shots, trail: steps),
    );
  }

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'Feedback or a bug',
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Material(
              color: context.cs.secondaryContainer.withValues(alpha: 0.92),
              shape: const CircleBorder(),
              elevation: 2,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _open,
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: _busy
                      ? const Padding(padding: EdgeInsets.all(11), child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(Icons.feedback_outlined, size: 20, color: context.cs.onSecondaryContainer),
                ),
              ),
            ),
            if (_hover && !_busy)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: IgnorePointer(
                  child: Material(
                    color: context.cs.inverseSurface.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      child: Text('Feedback or a bug', style: TextStyle(color: context.cs.onInverseSurface, fontSize: 12.5)),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      );
}

/// The screen as a PNG, clear and blurred (null where the device can't take one).
class Shots {
  final Uint8List clear, blurred;
  const Shots(this.clear, this.blurred);
}

Future<Shots?> captureScreen() async {
  try {
    final b = FeedbackLayer.captureKey.currentContext?.findRenderObject();
    if (b is! RenderRepaintBoundary) return null;
    final img = await b.toImage(pixelRatio: 1.0);
    final blurred = await _pixelate(img, 11);
    final c = await img.toByteData(format: ui.ImageByteFormat.png);
    final p = await blurred.toByteData(format: ui.ImageByteFormat.png);
    if (c == null || p == null) return null;
    return Shots(c.buffer.asUint8List(), p.buffer.asUint8List());
  } catch (e) {
    Trail.record('error', 'Screenshot failed: $e');
    return null;
  }
}

/// Blocks of [block] px: the layout and colours stay, no word or number can be read.
Future<ui.Image> _pixelate(ui.Image src, int block) async {
  final w = (src.width / block).ceil(), h = (src.height / block).ceil();
  final full = Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble());
  final small = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
  final r1 = ui.PictureRecorder();
  Canvas(r1).drawImageRect(src, full, small, Paint()..filterQuality = FilterQuality.medium);
  final tiny = await r1.endRecording().toImage(w, h);
  final r2 = ui.PictureRecorder();
  Canvas(r2).drawImageRect(tiny, small, full, Paint()..filterQuality = FilterQuality.none);
  return r2.endRecording().toImage(src.width, src.height);
}

class FeedbackSheet extends StatefulWidget {
  final DateTime pressedAt;
  final String screen;
  final Shots? shots;
  final List<Map<String, dynamic>> trail;
  const FeedbackSheet({required this.pressedAt, required this.screen, required this.shots, required this.trail, super.key});
  @override
  State<FeedbackSheet> createState() => _FeedbackSheetState();
}

class _FeedbackSheetState extends State<FeedbackSheet> {
  static const kinds = [
    ('love', 'Love this', Icons.favorite_outline, 'What do you like about it?'),
    ('dislike', "Don't like this", Icons.thumb_down_outlined, 'What would make it better?'),
    ('bug', 'Bug found', Icons.bug_report_outlined, 'What went wrong? What did you expect to happen?'),
  ];
  String? _kind;
  final _text = TextEditingController();
  bool _attach = true, _blur = true, _sending = false, _sent = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final kind = _kind;
    if (kind == null) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final shots = widget.shots;
    final size = MediaQuery.sizeOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    try {
      await AppScope.api(context).sendFeedback(
        kind: kind,
        message: _text.text.trim(),
        screen: widget.screen,
        pressedAt: widget.pressedAt,
        trail: widget.trail,
        client: {
          'build': kAppBuild.isEmpty ? 'dev' : kAppBuild,
          'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
          'screenSize': '${size.width.round()}x${size.height.round()}',
          'theme': dark ? 'dark' : 'light',
        },
        screenshot: kind == 'bug' && _attach && shots != null ? (_blur ? shots.blurred : shots.clear) : null,
        screenshotBlurred: _blur,
      );
      if (!mounted) return;
      setState(() => _sent = true);
      await Future<void>.delayed(const Duration(milliseconds: 1600));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final matches = kinds.where((k) => k.$1 == _kind);
    final current = matches.isEmpty ? null : matches.first;
    final shots = widget.shots;
    final canSend = _kind != null && !_sending && (_kind == 'love' || _text.text.trim().isNotEmpty);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('Feedback', style: context.tt.titleLarge),
          const SizedBox(height: 4),
          Text('Goes to OpenWorks IT, who build Steady. Never about a patient.', style: TextStyle(color: context.sc.ink2)),
          const SizedBox(height: 14),
          if (_sent)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Row(children: [
                Icon(Icons.check_circle, color: context.sc.calm),
                const SizedBox(width: 10),
                const Expanded(child: Text("Thank you. It's with the team.")),
              ]),
            )
          else ...[
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final k in kinds)
                ChoiceChip(
                  avatar: Icon(k.$3, size: 18),
                  label: Text(k.$2),
                  selected: _kind == k.$1,
                  onSelected: (_) => setState(() => _kind = k.$1),
                ),
            ]),
            if (current != null) ...[
              const SizedBox(height: 14),
              TextField(
                controller: _text,
                autofocus: true,
                maxLength: 2000,
                minLines: 3,
                maxLines: 6,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(labelText: current.$4, border: const OutlineInputBorder()),
              ),
              if (_kind == 'bug') ...[
                if (shots == null)
                  Text("A screenshot couldn't be taken on this device.", style: TextStyle(color: context.sc.ink3))
                else ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: Image.memory(_blur ? shots.blurred : shots.clear, fit: BoxFit.contain, gaplessPlayback: true),
                    ),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _attach,
                    onChanged: (v) => setState(() => _attach = v ?? true),
                    title: const Text('Attach this screenshot'),
                  ),
                  if (_attach)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _blur,
                      onChanged: (v) => setState(() => _blur = v ?? true),
                      title: const Text('Blur it so no patient can be read (recommended)'),
                    ),
                ],
                Text(
                  'We also send the screen you were on, the time and your last steps in the app (screens, taps and '
                  'server calls) so we can retrace what happened. Nothing you typed is included.',
                  style: context.tt.bodySmall?.copyWith(color: context.sc.ink3),
                ),
              ],
            ],
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: TextStyle(color: context.cs.error))),
            const SizedBox(height: 14),
            Row(children: [
              // the theme makes filled buttons full width: in a Row they need Expanded
              Expanded(child: FilledButton(onPressed: canSend ? _send : null, child: Text(_sending ? 'Sending...' : 'Send'))),
              const SizedBox(width: 10),
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
            ]),
          ],
        ]),
      ),
    );
  }
}
