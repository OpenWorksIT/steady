// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/api.dart';
import 'theme.dart';

String relTime(DateTime? t) {
  if (t == null) return '';
  final now = DateTime.now();
  final d = now.difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  if (day == today) return 'Today $hm';
  if (day == today.subtract(const Duration(days: 1))) return 'Yesterday $hm';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${t.day} ${months[t.month - 1]} $hm';
}

void showSnack(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));
}

/// Always visible on patient screens. Numbers are selectable and copyable.
class CrisisFooter extends StatelessWidget {
  const CrisisFooter({super.key});
  @override
  Widget build(BuildContext context) {
    final cfg = AppScope.of(context).config;
    return Container(
      padding: const EdgeInsets.only(top: 14),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: context.sc.line))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(cfg.crisisNotice, style: context.tt.bodySmall?.copyWith(color: context.sc.ink2)),
          const SizedBox(height: 8),
          for (final l in cfg.crisisLines)
            InkWell(
              onTap: () {
                Clipboard.setData(ClipboardData(text: l.number));
                showSnack(context, '${l.number} copied');
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Expanded(child: Text('${l.label} · ${l.hours}', style: context.tt.bodySmall?.copyWith(color: context.sc.ink2))),
                  SelectableText(l.number, style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                ]),
              ),
            ),
        ],
      ),
    );
  }
}

class FlagChip extends StatelessWidget {
  final String label;
  final Severity severity;
  const FlagChip(this.label, this.severity, {super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.sc.forSeverity(severity, context.cs);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(color: c.bg, borderRadius: BorderRadius.circular(99)),
      child: Text(label, style: TextStyle(color: c.fg, fontSize: 12, fontWeight: FontWeight.w700)),
    );
  }
}

class SectionHeader extends StatelessWidget {
  final String title;
  final String? trailing;
  const SectionHeader(this.title, {this.trailing, super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 4),
        child: Row(children: [
          Expanded(child: Text(title, style: context.tt.titleSmall?.copyWith(fontWeight: FontWeight.w700))),
          if (trailing != null) Text(trailing!, style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
        ]),
      );
}

/// Five large buttons, 1 to 5, with words for the ends.
class ScalePicker extends StatelessWidget {
  final String question, low, high;
  final int? value;
  final ValueChanged<int> onChanged;
  const ScalePicker({required this.question, required this.low, required this.high, required this.value, required this.onChanged, super.key});
  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: question,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(question, style: context.tt.titleMedium),
        const SizedBox(height: 8),
        Row(children: [
          for (var n = 1; n <= 5; n++) ...[
            if (n > 1) const SizedBox(width: 6),
            Expanded(
              child: Semantics(
                button: true,
                selected: value == n,
                label: '$n of 5${n == 1 ? ', $low' : n == 5 ? ', $high' : ''}',
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => onChanged(n),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    height: 48,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: value == n ? context.cs.primary : context.cs.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: value == n ? context.cs.primary : context.sc.line, width: 1.5),
                    ),
                    child: Text('$n',
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: value == n ? context.cs.onPrimary : context.cs.onSurface)),
                  ),
                ),
              ),
            ),
          ],
        ]),
        const SizedBox(height: 4),
        Row(children: [
          Text(low, style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
          const Spacer(),
          Text(high, style: context.tt.bodySmall?.copyWith(color: context.sc.ink3)),
        ]),
      ]),
    );
  }
}

class Avatar extends StatelessWidget {
  final String initials;
  const Avatar(this.initials, {super.key});
  @override
  Widget build(BuildContext context) => CircleAvatar(
        radius: 20,
        backgroundColor: context.sc.accentSoft,
        child: Text(initials, style: TextStyle(color: context.cs.primary, fontWeight: FontWeight.w700, fontSize: 14)),
      );
}

class Glyph extends StatelessWidget {
  final IconData icon;
  final bool calm;
  const Glyph(this.icon, {this.calm = false, super.key});
  @override
  Widget build(BuildContext context) => Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(color: calm ? context.sc.calmSoft : context.sc.accentSoft, borderRadius: BorderRadius.circular(12)),
        child: Icon(icon, size: 21, color: calm ? context.sc.calm : context.cs.primary),
      );
}

IconData iconFor(Instrument? i) {
  if (i == null) return Icons.assignment_outlined;
  if (i.isQuestionnaire) return Icons.assignment_outlined;
  return i.exercise?.type == 'breathing' ? Icons.air : Icons.spa_outlined;
}

/// Loads data, shows a spinner, an error with retry, or the content.
class Loader<T> extends StatefulWidget {
  final Future<T> Function() load;
  final Widget Function(BuildContext, T, Future<void> Function() reload) builder;
  const Loader({required this.load, required this.builder, super.key});
  @override
  State<Loader<T>> createState() => _LoaderState<T>();
}

class _LoaderState<T> extends State<Loader<T>> {
  T? _data;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = _data == null);
    try {
      final d = await widget.load();
      if (!mounted) return;
      setState(() {
        _data = d;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _data == null) return const Center(child: CircularProgressIndicator());
    if (_error != null && _data == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(errorText(_error!), textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _reload, child: const Text('Try again')),
          ]),
        ),
      );
    }
    return RefreshIndicator(onRefresh: _reload, child: widget.builder(context, _data as T, _reload));
  }
}

/// Mood/anxiety line chart over 14 days, 1-5 scale.
class TrendChart extends StatelessWidget {
  final List<double?> mood, anxiety;
  const TrendChart({required this.mood, required this.anxiety, super.key});
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Semantics(
        label: 'Mood and anxiety over the last 14 days',
        child: SizedBox(
          height: 150,
          width: double.infinity,
          child: CustomPaint(
            painter: _TrendPainter(mood, anxiety, context.cs.primary, context.sc.warn, context.sc.line, context.sc.ink3),
          ),
        ),
      ),
      const SizedBox(height: 6),
      Wrap(spacing: 14, children: [
        _legend(context, context.cs.primary, 'Mood'),
        _legend(context, context.sc.warn, 'Anxiety (higher = more anxious)'),
      ]),
    ]);
  }

  Widget _legend(BuildContext c, Color col, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 14, height: 3, color: col),
        const SizedBox(width: 6),
        Text(t, style: c.tt.bodySmall?.copyWith(color: c.sc.ink2)),
      ]);
}

class _TrendPainter extends CustomPainter {
  final List<double?> mood, anxiety;
  final Color moodC, anxC, grid, label;
  _TrendPainter(this.mood, this.anxiety, this.moodC, this.anxC, this.grid, this.label);

  @override
  void paint(Canvas canvas, Size size) {
    const left = 22.0, bottom = 20.0, top = 6.0, right = 6.0;
    final w = size.width - left - right, h = size.height - top - bottom;
    final n = mood.length < 2 ? 2 : mood.length;
    double x(int i) => left + i * w / (n - 1);
    double y(double v) => top + (5 - v) * h / 4;
    final gp = Paint()
      ..color = grid
      ..strokeWidth = 0.7;
    for (var v = 1; v <= 5; v++) {
      canvas.drawLine(Offset(left, y(v.toDouble())), Offset(size.width - right, y(v.toDouble())), gp);
      _text(canvas, '$v', Offset(left - 14, y(v.toDouble()) - 6));
    }
    _text(canvas, '14 days ago', Offset(left, size.height - 14));
    _text(canvas, 'Today', Offset(size.width - right - 30, size.height - 14));
    _series(canvas, anxiety, anxC, x, y, dashed: true);
    _series(canvas, mood, moodC, x, y);
  }

  void _series(Canvas c, List<double?> vals, Color col, double Function(int) x, double Function(double) y, {bool dashed = false}) {
    final p = Paint()
      ..color = col
      ..strokeWidth = dashed ? 1.8 : 2.4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    Offset? prev;
    for (var i = 0; i < vals.length; i++) {
      final v = vals[i];
      if (v == null) {
        prev = null;
        continue;
      }
      final pt = Offset(x(i), y(v));
      if (prev != null) {
        if (dashed) {
          final d = pt - prev;
          final len = d.distance;
          for (double s = 0; s < len; s += 7) {
            final a = prev + d * (s / len), b = prev + d * ((s + 4).clamp(0, len) / len);
            c.drawLine(a, b, p);
          }
        } else {
          c.drawLine(prev, pt, p);
        }
      }
      c.drawCircle(pt, 2.8, Paint()..color = col);
      prev = pt;
    }
  }

  void _text(Canvas c, String s, Offset at) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: label, fontSize: 10)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, at);
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) => old.mood != mood || old.anxiety != anxiety || old.moodC != moodC;
}

class Sparkline extends StatelessWidget {
  final List<double?> values;
  const Sparkline(this.values, {super.key});
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 70,
        height: 22,
        child: CustomPaint(painter: _SparkPainter(values, context.cs.primary)),
      );
}

class _SparkPainter extends CustomPainter {
  final List<double?> v;
  final Color c;
  _SparkPainter(this.v, this.c);
  @override
  void paint(Canvas canvas, Size s) {
    if (v.length < 2) return;
    final p = Paint()
      ..color = c
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    Offset? prev, last;
    for (var i = 0; i < v.length; i++) {
      final val = v[i];
      if (val == null) {
        prev = null;
        continue;
      }
      final pt = Offset(2 + i * (s.width - 4) / (v.length - 1), s.height - 2 - (val - 1) * (s.height - 4) / 4);
      if (prev != null) canvas.drawLine(prev, pt, p);
      prev = pt;
      last = pt;
    }
    if (last != null) canvas.drawCircle(last, 2.4, Paint()..color = c);
  }

  @override
  bool shouldRepaint(covariant _SparkPainter o) => o.v != v;
}

/// A primary action with a busy state, so taps can't double-submit.
class BusyButton extends StatefulWidget {
  final String label;
  final Future<void> Function()? onPressed;
  const BusyButton({required this.label, required this.onPressed, super.key});
  @override
  State<BusyButton> createState() => _BusyButtonState();
}

class _BusyButtonState extends State<BusyButton> {
  bool _busy = false;
  @override
  Widget build(BuildContext context) => FilledButton(
        onPressed: widget.onPressed == null || _busy
            ? null
            : () async {
                setState(() => _busy = true);
                try {
                  await widget.onPressed!();
                } catch (e) {
                  if (context.mounted) showSnack(context, errorText(e));
                } finally {
                  if (mounted) setState(() => _busy = false);
                }
              },
        child: _busy
            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
            : Text(widget.label),
      );
}
