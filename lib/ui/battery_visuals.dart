/// Custom-painted battery visuals for the dashboard: the charge ring, the
/// min/avg/max spread rows, and the SoH history chart. No chart dependency:
/// three small painters are easier to keep honest than a general library.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../engine/soh_history.dart';

// ---------------------------------------------------------------------------
// Charge ring
// ---------------------------------------------------------------------------

/// Displayed state of charge as a thick 270° ring. When the vehicle reports
/// its usable window (the slice of raw cell capacity the car lets you use), a
/// thin outer ring shows the full raw range, the window band, and where the
/// cells sit right now — the "why does 100 % not mean full" picture.
class ChargeRing extends StatelessWidget {
  final double socPct;
  final double? windowMinPct;
  final double? windowMaxPct;
  final double? cellSocPct;
  final double size;

  const ChargeRing({
    super.key,
    required this.socPct,
    this.windowMinPct,
    this.windowMaxPct,
    this.cellSocPct,
    this.size = 140,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _ChargeRingPainter(
          soc: socPct,
          windowMin: windowMinPct,
          windowMax: windowMaxPct,
          cellSoc: cellSocPct,
          track: cs.surfaceContainerHighest,
          fill: _socColor(cs, socPct),
          window: cs.tertiary,
          marker: cs.onSurface,
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${socPct.toStringAsFixed(0)} %',
                  style: text.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
              Text('charge', style: text.bodySmall),
            ],
          ),
        ),
      ),
    );
  }

  /// Low charge reads as a warning; otherwise the theme's primary.
  static Color _socColor(ColorScheme cs, double soc) =>
      soc < 15 ? cs.error : cs.primary;
}

class _ChargeRingPainter extends CustomPainter {
  final double soc;
  final double? windowMin, windowMax, cellSoc;
  final Color track, fill, window, marker;

  _ChargeRingPainter({
    required this.soc,
    required this.windowMin,
    required this.windowMax,
    required this.cellSoc,
    required this.track,
    required this.fill,
    required this.window,
    required this.marker,
  });

  static const _start = math.pi * 0.75; // 7:30 o'clock
  static const _sweep = math.pi * 1.5; // 270°

  double _a(double pct) => _start + _sweep * (pct.clamp(0, 100) / 100);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final hasWindow = windowMin != null && windowMax != null;
    final outerR = size.shortestSide / 2 - 3;
    final innerR = hasWindow ? outerR - 14 : outerR - 8;
    const thick = 12.0;

    Paint stroke(Color color, double w) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round;

    final inner = Rect.fromCircle(center: c, radius: innerR);
    canvas.drawArc(inner, _start, _sweep, false, stroke(track, thick));
    if (soc > 0) {
      canvas.drawArc(inner, _start, _sweep * (soc.clamp(0, 100) / 100), false,
          stroke(fill, thick));
    }

    if (hasWindow) {
      final outer = Rect.fromCircle(center: c, radius: outerR);
      canvas.drawArc(outer, _start, _sweep, false,
          stroke(track, 4)..strokeCap = StrokeCap.butt);
      canvas.drawArc(outer, _a(windowMin!), _a(windowMax!) - _a(windowMin!),
          false, stroke(window, 4)..strokeCap = StrokeCap.butt);
      if (cellSoc != null) {
        final a = _a(cellSoc!);
        canvas.drawCircle(c + Offset(math.cos(a), math.sin(a)) * outerR, 4,
            Paint()..color = marker);
      }
    }
  }

  @override
  bool shouldRepaint(_ChargeRingPainter o) =>
      o.soc != soc ||
      o.windowMin != windowMin ||
      o.windowMax != windowMax ||
      o.cellSoc != cellSoc ||
      o.fill != fill ||
      o.track != track;
}

// ---------------------------------------------------------------------------
// Spread rows
// ---------------------------------------------------------------------------

/// How a min/max spread should be read, by unit. Generic engineering rules of
/// thumb for lithium-ion packs, not vehicle-specific values.
enum SpreadVerdict { good, watch, check }

class SpreadScale {
  /// Track domain: where the values sit within a meaningful range.
  final double lo, hi;

  /// Spread thresholds (in the display unit of [spreadUnit]).
  final double watchAt, checkAt;
  final String spreadUnit;
  final double spreadFactor; // value units -> spread display units
  final int decimals;

  const SpreadScale(this.lo, this.hi, this.watchAt, this.checkAt,
      this.spreadUnit, this.spreadFactor, this.decimals);

  /// Pick a scale from the unit and magnitude. Cell voltages (< 5 V) use a
  /// lithium-ion working range and judge spread in mV (healthy packs at rest
  /// sit under ~20 mV; > 50 mV deserves a look). Percent and °C judge spread
  /// in points / degrees.
  static SpreadScale forUnit(String unit, double min, double max) {
    switch (unit) {
      case 'volts' when max < 5:
        return const SpreadScale(3.0, 4.3, 20, 50, 'mV', 1000, 3);
      case 'percent':
        return const SpreadScale(0, 100, 5, 10, 'pts', 1, 1);
      case 'celsius':
        return const SpreadScale(-10, 50, 5, 10, '°C', 1, 1);
      default:
        final pad = math.max((max - min).abs(), max.abs() * 0.05 + 1e-9);
        return SpreadScale(min - pad, max + pad, double.infinity,
            double.infinity, _shortUnit(unit), 1, 2);
    }
  }

  /// Same track, but the spread is shown without a good/watch/check verdict:
  /// for mixed sensor sets where a balance judgement would mislead.
  SpreadScale get unjudged => SpreadScale(lo, hi, double.infinity,
      double.infinity, spreadUnit, spreadFactor, decimals);

  bool get judges => watchAt.isFinite;

  static String _shortUnit(String unit) => switch (unit) {
        'volts' => 'V',
        'percent' => '%',
        'celsius' => '°C',
        'amps' => 'A',
        _ => unit,
      };

  SpreadVerdict verdict(double spread) {
    final s = spread * spreadFactor;
    if (s >= checkAt) return SpreadVerdict.check;
    if (s >= watchAt) return SpreadVerdict.watch;
    return SpreadVerdict.good;
  }
}

/// One min/avg/max row: the label and spread chip, a track showing where the
/// values sit in their working range, and the three numbers.
class SpreadRow extends StatelessWidget {
  final String label;
  final String unitLabel;
  final double min, max;
  final double? avg;
  final SpreadScale scale;
  final String? note;

  const SpreadRow({
    super.key,
    required this.label,
    required this.unitLabel,
    required this.min,
    required this.max,
    required this.scale,
    this.avg,
    this.note,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final spread = (max - min).abs();
    final verdict = scale.verdict(spread);
    final chipColor = !scale.judges
        ? cs.onSurfaceVariant
        : switch (verdict) {
            SpreadVerdict.good => Colors.green,
            SpreadVerdict.watch => Colors.amber,
            SpreadVerdict.check => cs.error,
          };
    String f(double v) => v.toStringAsFixed(scale.decimals);
    final spreadText =
        '${(spread * scale.spreadFactor).toStringAsFixed(scale.spreadFactor >= 1000 ? 0 : 1)} ${scale.spreadUnit}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: text.titleSmall)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: chipColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('spread $spreadText',
                    style: text.labelSmall?.copyWith(color: chipColor)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 14,
            width: double.infinity,
            child: CustomPaint(
              painter: _SpreadPainter(
                lo: scale.lo,
                hi: scale.hi,
                min: min,
                max: max,
                avg: avg,
                track: cs.surfaceContainerHighest,
                band: cs.primary,
                tick: cs.onSurface,
              ),
            ),
          ),
          const SizedBox(height: 6),
          // Each number gets an equal third and scales down rather than
          // overflowing on narrow phones.
          Row(
            children: [
              _cell(_num(context, 'min', f(min), unitLabel),
                  Alignment.centerLeft),
              _cell(
                  avg == null
                      ? const SizedBox.shrink()
                      : _num(context, 'avg', f(avg!), unitLabel),
                  Alignment.center),
              _cell(_num(context, 'max', f(max), unitLabel),
                  Alignment.centerRight),
            ],
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(note!, style: text.bodySmall),
            ),
        ],
      ),
    );
  }

  Widget _cell(Widget child, Alignment align) => Expanded(
        child: FittedBox(fit: BoxFit.scaleDown, alignment: align, child: child),
      );

  Widget _num(BuildContext context, String k, String v, String unit) {
    final text = Theme.of(context).textTheme;
    return Text.rich(TextSpan(children: [
      TextSpan(text: '$k ', style: text.bodySmall),
      TextSpan(
          text: v,
          style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
      TextSpan(text: ' $unit', style: text.bodySmall),
    ]));
  }
}

class _SpreadPainter extends CustomPainter {
  final double lo, hi, min, max;
  final double? avg;
  final Color track, band, tick;

  _SpreadPainter({
    required this.lo,
    required this.hi,
    required this.min,
    required this.max,
    required this.avg,
    required this.track,
    required this.band,
    required this.tick,
  });

  @override
  void paint(Canvas canvas, Size size) {
    double x(double v) => ((v - lo) / (hi - lo)).clamp(0.0, 1.0) * size.width;
    final mid = size.height / 2;
    final r = Radius.circular(size.height / 2);
    canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(0, mid - 3, size.width, 6), r),
        Paint()..color = track);
    // The band is at least a dot wide so a tight pack is still visible.
    var x0 = x(min), x1 = x(max);
    if (x1 - x0 < size.height) {
      final m = (x0 + x1) / 2;
      x0 = m - size.height / 2;
      x1 = m + size.height / 2;
    }
    canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTRB(x0, 0, x1, size.height), r),
        Paint()..color = band);
    if (avg != null) {
      final xa = x(avg!);
      canvas.drawLine(
          Offset(xa, -2),
          Offset(xa, size.height + 2),
          Paint()
            ..color = tick
            ..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(_SpreadPainter o) =>
      o.min != min || o.max != max || o.avg != avg || o.lo != lo || o.hi != hi;
}

// ---------------------------------------------------------------------------
// SoH history chart
// ---------------------------------------------------------------------------

class SohSeriesStyle {
  final String label;
  final Color color;
  const SohSeriesStyle(this.label, this.color);
}

/// SoH over time, one line per source. The y-axis hugs the data (padded to at
/// least a 6-point window) because SoH moves a point or two a year — on a
/// 0-100 axis every history would be a flat line.
class SohHistoryChart extends StatelessWidget {
  final Map<SohSource, List<SohEntry>> series;
  final Map<SohSource, SohSeriesStyle> styles;
  final double height;

  const SohHistoryChart({
    super.key,
    required this.series,
    required this.styles,
    this.height = 120,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final all = series.values.expand((s) => s).toList()
      ..sort((a, b) => a.at.compareTo(b.at));
    if (all.isEmpty) return const SizedBox.shrink();
    final ys = all.map((e) => e.sohPct);
    var yLo = ys.reduce(math.min).floorToDouble() - 1;
    var yHi = math.min(100.0, ys.reduce(math.max).ceilToDouble() + 1);
    if (yHi - yLo < 6) {
      final m = (yHi + yLo) / 2;
      yLo = m - 3;
      yHi = math.min(100.0, m + 3);
      if (yHi - yLo < 6) yLo = yHi - 6;
    }
    String d(DateTime t) =>
        '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(
            painter: _SohPainter(
              series: series,
              colors: {for (final e in styles.entries) e.key: e.value.color},
              t0: all.first.at,
              t1: all.last.at,
              yLo: yLo,
              yHi: yHi,
              grid: cs.outlineVariant,
              label: text.labelSmall ?? const TextStyle(fontSize: 10),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(d(all.first.at), style: text.labelSmall),
            const Spacer(),
            if (all.length > 1) Text(d(all.last.at), style: text.labelSmall),
          ],
        ),
        if (series.length > 1)
          Wrap(
            spacing: 12,
            children: [
              for (final s in series.keys)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 10, height: 3, color: styles[s]!.color),
                  const SizedBox(width: 4),
                  Text(styles[s]!.label, style: text.labelSmall),
                ]),
            ],
          ),
      ],
    );
  }
}

class _SohPainter extends CustomPainter {
  final Map<SohSource, List<SohEntry>> series;
  final Map<SohSource, Color> colors;
  final DateTime t0, t1;
  final double yLo, yHi;
  final Color grid;
  final TextStyle label;

  _SohPainter({
    required this.series,
    required this.colors,
    required this.t0,
    required this.t1,
    required this.yLo,
    required this.yHi,
    required this.grid,
    required this.label,
  });

  static const _left = 28.0;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width - _left;
    final span = t1.difference(t0).inMilliseconds;
    double x(DateTime t) => span == 0
        ? _left + w / 2
        : _left + w * t.difference(t0).inMilliseconds / span;
    double y(double v) => size.height * (1 - (v - yLo) / (yHi - yLo));

    // Horizontal grid at whole-percent steps, labelled.
    final step = (yHi - yLo) > 12 ? 5 : ((yHi - yLo) > 6 ? 2 : 1);
    final gp = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var v = (yLo / step).ceil() * step; v <= yHi; v += step) {
      final yy = y(v.toDouble());
      canvas.drawLine(Offset(_left, yy), Offset(size.width, yy), gp);
      final tp = TextPainter(
          text: TextSpan(text: '$v', style: label),
          textDirection: TextDirection.ltr)
        ..layout();
      tp.paint(canvas, Offset(_left - tp.width - 4, yy - tp.height / 2));
    }

    for (final MapEntry(key: src, value: pts) in series.entries) {
      if (pts.isEmpty) continue;
      final color = colors[src] ?? grid;
      final line = Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      final path = Path()..moveTo(x(pts.first.at), y(pts.first.sohPct));
      for (final p in pts.skip(1)) {
        path.lineTo(x(p.at), y(p.sohPct));
      }
      canvas.drawPath(path, line);
      final dot = Paint()..color = color;
      for (final p in pts) {
        canvas.drawCircle(Offset(x(p.at), y(p.sohPct)), 3, dot);
      }
    }
  }

  @override
  bool shouldRepaint(_SohPainter o) => true;
}
