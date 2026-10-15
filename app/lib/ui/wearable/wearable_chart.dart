// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../wearable/metrics.dart';
import '../theme.dart';

class ChartPoint {
  final String label;
  final double? value, low, high; // low/high for range charts
  final double? bandLo, bandHi; // the patient's usual range
  const ChartPoint(this.label, {this.value, this.low, this.high, this.bandLo, this.bandHi});
  bool get hasValue => value != null || (low != null && high != null);
}

/// Bars, lines or min-max ranges over time, with the patient's usual range shaded behind.
class WearableChart extends StatelessWidget {
  final List<ChartPoint> points;
  final WearableMetric metric;
  final double height;
  final bool compact;
  final int? selected;
  final ValueChanged<int>? onTap;
  const WearableChart({
    required this.points,
    required this.metric,
    this.height = 200,
    this.compact = false,
    this.selected,
    this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final painter = _ChartPainter(
      points: points,
      metric: metric,
      compact: compact,
      selected: selected,
      colour: context.cs.primary,
      rangeColour: context.cs.primary.withValues(alpha: 0.35),
      band: context.sc.line.withValues(alpha: 0.75),
      grid: context.sc.line,
      text: context.sc.ink3,
    );
    return Semantics(
      label: '${metric.label} chart',
      child: LayoutBuilder(builder: (context, c) {
        return GestureDetector(
          onTapUp: onTap == null
              ? null
              : (d) {
                  final i = painter.indexAt(d.localPosition.dx, c.maxWidth);
                  if (i != null) onTap!(i);
                },
          child: SizedBox(height: height, width: double.infinity, child: CustomPaint(painter: painter)),
        );
      }),
    );
  }
}

class _ChartPainter extends CustomPainter {
  final List<ChartPoint> points;
  final WearableMetric metric;
  final bool compact;
  final int? selected;
  final Color colour, rangeColour, band, grid, text;
  _ChartPainter({
    required this.points,
    required this.metric,
    required this.compact,
    required this.selected,
    required this.colour,
    required this.rangeColour,
    required this.band,
    required this.grid,
    required this.text,
  });

  double get _left => compact ? 2 : 38;
  double get _bottom => compact ? 2 : 20;
  static const _top = 6.0, _right = 4.0;

  int? indexAt(double dx, double width) {
    if (points.isEmpty) return null;
    final slot = (width - _left - _right) / points.length;
    final i = ((dx - _left) / slot).floor();
    return (i >= 0 && i < points.length) ? i : null;
  }

  (double, double, double) _scale() {
    final vals = <double>[];
    for (final p in points) {
      for (final v in [p.value, p.low, p.high, p.bandLo, p.bandHi]) {
        if (v != null) vals.add(v);
      }
    }
    if (vals.isEmpty) return (0, 1, 1);
    var lo = vals.reduce(math.min), hi = vals.reduce(math.max);
    if (metric.kind == ChartKind.bar) lo = 0;
    if (hi == lo) {
      hi += 1;
      lo -= metric.kind == ChartKind.bar ? 0 : 1;
    }
    final minutes = metric.key.startsWith('sleep');
    var step = _nice((hi - lo) / 4);
    if (minutes) step = math.max(60, (step / 60).ceil() * 60.0);
    lo = (lo / step).floor() * step;
    hi = (hi / step).ceil() * step;
    if (hi == lo) hi = lo + step;
    return (lo, hi, step);
  }

  static double _nice(double raw) {
    if (raw <= 0) return 1;
    final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    for (final m in [1.0, 2.0, 2.5, 5.0, 10.0]) {
      if (raw <= m * mag) return m * mag;
    }
    return 10 * mag;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width - _left - _right, h = size.height - _top - _bottom;
    if (w <= 0 || h <= 0 || points.isEmpty) return;
    final (lo, hi, step) = _scale();
    double y(double v) => _top + (hi - v) / (hi - lo) * h;
    final slot = w / points.length;
    double x(int i) => _left + (i + 0.5) * slot;

    // grid and axis labels
    if (!compact) {
      final gp = Paint()
        ..color = grid
        ..strokeWidth = 0.6;
      for (var v = lo; v <= hi + 0.0001; v += step) {
        canvas.drawLine(Offset(_left, y(v)), Offset(size.width - _right, y(v)), gp);
        _text(canvas, metric.axis(v), Offset(0, y(v) - 6), width: _left - 6, alignRight: true);
      }
    }

    // usual range: a soft band joining neighbouring days
    final bp = Paint()..color = band;
    var i = 0;
    while (i < points.length) {
      if (points[i].bandLo == null || points[i].bandHi == null) {
        i++;
        continue;
      }
      var j = i;
      while (j + 1 < points.length && points[j + 1].bandLo != null && points[j + 1].bandHi != null) {
        j++;
      }
      final path = Path()..moveTo(x(i) - slot / 2, y(points[i].bandHi!));
      for (var k = i; k <= j; k++) {
        path.lineTo(x(k), y(points[k].bandHi!));
      }
      path.lineTo(x(j) + slot / 2, y(points[j].bandHi!));
      path.lineTo(x(j) + slot / 2, y(points[j].bandLo!));
      for (var k = j; k >= i; k--) {
        path.lineTo(x(k), y(points[k].bandLo!));
      }
      path.lineTo(x(i) - slot / 2, y(points[i].bandLo!));
      path.close();
      canvas.drawPath(path, bp);
      i = j + 1;
    }

    // selection
    if (selected != null && selected! >= 0 && selected! < points.length) {
      canvas.drawRect(
        Rect.fromLTWH(x(selected!) - slot / 2, _top, slot, h),
        Paint()..color = colour.withValues(alpha: 0.08),
      );
    }

    final dot = Paint()..color = colour;
    switch (metric.kind) {
      case ChartKind.bar:
        final bw = math.max(2.0, slot * 0.6);
        for (var k = 0; k < points.length; k++) {
          final v = points[k].value;
          if (v == null) continue;
          final r = RRect.fromRectAndCorners(
            Rect.fromLTRB(x(k) - bw / 2, y(v), x(k) + bw / 2, y(lo)),
            topLeft: Radius.circular(math.min(4, bw / 2)),
            topRight: Radius.circular(math.min(4, bw / 2)),
          );
          canvas.drawRRect(r, Paint()..color = (selected == null || selected == k) ? colour : colour.withValues(alpha: 0.7));
        }
      case ChartKind.range:
        final bw = math.max(3.0, math.min(10.0, slot * 0.35));
        for (var k = 0; k < points.length; k++) {
          final p = points[k];
          if (p.low != null && p.high != null) {
            canvas.drawRRect(
              RRect.fromRectAndRadius(Rect.fromLTRB(x(k) - bw / 2, y(p.high!), x(k) + bw / 2, y(p.low!)), Radius.circular(bw / 2)),
              Paint()..color = rangeColour,
            );
          }
          if (p.value != null) canvas.drawCircle(Offset(x(k), y(p.value!)), compact ? 2 : 3, dot);
        }
      case ChartKind.line:
        final lp = Paint()
          ..color = colour
          ..strokeWidth = compact ? 1.6 : 2.2
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round;
        Offset? prev;
        for (var k = 0; k < points.length; k++) {
          final v = points[k].value;
          if (v == null) {
            prev = null;
            continue;
          }
          final pt = Offset(x(k), y(v));
          if (prev != null) canvas.drawLine(prev, pt, lp);
          canvas.drawCircle(pt, compact ? 2 : 3, dot);
          prev = pt;
        }
    }

    // x labels, thinned to fit
    if (!compact) {
      final every = (points.length / 7).ceil().clamp(1, 1000);
      for (var k = 0; k < points.length; k++) {
        if (k % every != 0 && k != points.length - 1) continue;
        if (k != points.length - 1 && points.length - 1 - k < every && k % every == 0 && k != 0) continue;
        _text(canvas, points[k].label, Offset(x(k) - 24, size.height - 15), width: 48, center: true);
      }
    }
  }

  void _text(Canvas c, String s, Offset at, {double width = 60, bool alignRight = false, bool center = false}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: text, fontSize: 10)),
      textDirection: TextDirection.ltr,
      textAlign: alignRight ? TextAlign.right : (center ? TextAlign.center : TextAlign.left),
      maxLines: 1,
    )..layout(minWidth: width, maxWidth: width);
    tp.paint(c, at);
  }

  @override
  bool shouldRepaint(covariant _ChartPainter o) =>
      o.points != points || o.selected != selected || o.metric != metric || o.colour != colour;
}
