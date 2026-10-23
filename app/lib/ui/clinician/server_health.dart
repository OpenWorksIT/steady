// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Settings > Server and updates > Server health: how quickly this server answers, its database
// size, and (when deploy/ctl is installed) disk and memory. The server keeps the figures
// (server/pb_hooks/lib/health.js); OpenWorks IT reads the same with deploy/health.sh.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../theme.dart';
import '../../services/api.dart';

class ServerHealthCard extends StatefulWidget {
  const ServerHealthCard({super.key});
  @override
  State<ServerHealthCard> createState() => _ServerHealthCardState();
}

class _ServerHealthCardState extends State<ServerHealthCard> {
  Map<String, dynamic>? _h;
  String? _error;
  bool _loading = false;

  static Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
  static num? _num(Object? v) => v is num ? v : null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final h = await AppScope.api(context).serverHealth();
      if (mounted) {
        setState(() {
          _h = h;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  String _ms(Object? v) => _num(v) == null ? '-' : '${_num(v)!.round()} ms';
  String _size(num bytes) => bytes >= 1073741824
      ? '${(bytes / 1073741824).toStringAsFixed(1)} GB'
      : '${(bytes / 1048576).toStringAsFixed(bytes < 10485760 ? 1 : 0)} MB';

  @override
  Widget build(BuildContext context) {
    final h = _h;
    final health = _map(h?['health']);
    final status = '${health['status'] ?? ''}';
    final reasons = (health['reasons'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
    final hour = _map(_map(h?['windows'])['lastHour']);
    final day = _map(_map(h?['windows'])['last24h']);
    final host = _map(h?['host']);
    final disk = _map(host['disk']);
    final mem = _map(host['memory']);
    final series = ((h?['series'] as List?) ?? const []).map(_map).toList();
    final (fg, bg) = switch (status) {
      'good' => (context.sc.calm, context.sc.calmSoft),
      'slow' => (context.sc.warn, context.sc.warnSoft),
      'struggling' => (context.sc.alert, context.sc.alertSoft),
      _ => (context.sc.ink2, context.sc.surface2),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('Server health', style: context.tt.titleMedium)),
            IconButton(
              tooltip: 'Refresh',
              onPressed: _loading ? null : _load,
              icon: _loading ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh),
            ),
          ]),
          if (_error != null) Text(_error!, style: TextStyle(color: context.cs.error)),
          if (h != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
              child: Text(
                switch (status) { 'good' => 'Running well', 'slow' => 'A little slow', 'struggling' => 'Struggling', _ => status },
                style: TextStyle(color: fg, fontWeight: FontWeight.w600),
              ),
            ),
            if (reasons.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6, right: 8), child: Text(reasons.join('; '), style: TextStyle(color: context.sc.ink2))),
            const SizedBox(height: 10),
            Text('Last hour: ${hour['requests'] ?? 0} requests · 95% answered within ${_ms(hour['p95'])} · '
                'database check ${_ms(hour['probeMedian'])}${(_num(hour['errors']) ?? 0) > 0 ? ' · ${hour['errors']} errors' : ''}',
                style: TextStyle(color: context.sc.ink2)),
            const SizedBox(height: 10),
            if (series.length >= 2)
              SizedBox(
                height: 110,
                child: CustomPaint(
                  size: Size.infinite,
                  painter: _LagChart(series, context.cs.primary, context.sc.ink3, context.sc.line, Theme.of(context).textTheme.labelSmall!),
                ),
              )
            else
              Text('The chart fills in as the server records each minute.', style: TextStyle(color: context.sc.ink3)),
            const SizedBox(height: 4),
            Text('Slowest 5% of requests (ms), last ${h['stepMinutes'] == 60 ? 'days' : '24 hours'}', style: context.tt.labelSmall?.copyWith(color: context.sc.ink3)),
            const SizedBox(height: 10),
            Wrap(spacing: 18, runSpacing: 4, children: [
              Text('Database ${_size(_num(_map(h['database'])['bytes']) ?? 0)}'),
              Text('${_map(h['counts'])['patients'] ?? '-'} active patients'),
              if (disk.isNotEmpty) Text('Disk ${_size(_num(disk['used']) ?? 0)} of ${_size(_num(disk['total']) ?? 0)}'),
              if (mem.isNotEmpty) Text('Memory free ${_size(_num(mem['available']) ?? 0)} of ${_size(_num(mem['total']) ?? 0)}'),
            ]),
            if (host.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Disk and memory appear once OpenWorks has run deploy/ctl/install.sh on the server.', style: TextStyle(color: context.sc.ink3)),
              ),
            if (((day['slow'] as List?) ?? const []).isNotEmpty)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Slowest kinds of request today'),
                children: [
                  for (final s in (day['slow'] as List).map(_map))
                    ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text('${s['route']}'), trailing: Text(_ms(s['worstMs']))),
                ],
              ),
          ],
        ]),
      ),
    );
  }
}

/// The slowest 5% of requests over time, with the database check below it.
class _LagChart extends CustomPainter {
  final List<Map<String, dynamic>> points;
  final Color line, quiet, grid;
  final TextStyle label;
  _LagChart(this.points, this.line, this.quiet, this.grid, this.label);

  @override
  void paint(Canvas canvas, Size size) {
    double? v(Map<String, dynamic> p, String k) => p[k] is num ? (p[k] as num).toDouble() : null;
    final values = points.expand((p) => [v(p, 'p95'), v(p, 'probe')]).whereType<double>().toList();
    final top = math.max(500.0, values.isEmpty ? 500.0 : values.reduce(math.max) * 1.1);
    const left = 34.0;
    final w = size.width - left, h = size.height - 4;
    double y(double ms) => h - (ms / top) * h;
    double x(int i) => left + w * i / (points.length - 1);
    final g = Paint()..color = grid..strokeWidth = 1;
    for (final t in [0.0, top / 2, top]) {
      canvas.drawLine(Offset(left, y(t)), Offset(size.width, y(t)), g);
      final tp = TextPainter(text: TextSpan(text: t.round().toString(), style: label.copyWith(color: quiet)), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, Offset(0, y(t) - tp.height / 2));
    }
    void draw(String key, Color c, double width) {
      final path = Path();
      var pen = false;
      for (var i = 0; i < points.length; i++) {
        final val = v(points[i], key);
        if (val == null) {
          pen = false;
          continue;
        }
        pen ? path.lineTo(x(i), y(val)) : path.moveTo(x(i), y(val));
        pen = true;
      }
      canvas.drawPath(path, Paint()..color = c..strokeWidth = width..style = PaintingStyle.stroke);
    }

    draw('probe', quiet, 1.2);
    draw('p95', line, 2);
  }

  @override
  bool shouldRepaint(_LagChart old) => old.points != points;
}
