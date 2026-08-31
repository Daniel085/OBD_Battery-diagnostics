import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/app_controller.dart';
import '../engine/drive_session.dart';

/// Drive mode: a live EV power meter. The poll loop switches to hammering the
/// pack-current DID alone (~5-15 Hz on a real adapter), showing instantaneous
/// kW draw/regen, a rolling power graph, and per-session energy stats —
/// the "Scan My Tesla" view for Ultium, over a generic BLE adapter.
class DriveScreen extends StatefulWidget {
  const DriveScreen({super.key});

  @override
  State<DriveScreen> createState() => _DriveScreenState();
}

class _DriveScreenState extends State<DriveScreen> {
  bool _started = false;
  bool _unsupported = false;

  /// Cached so dispose() can stop drive mode without touching the (by then
  /// deactivated) BuildContext.
  AppController? _controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final c = context.read<AppController>();
      _controller = c;
      final ok = c.startDriveMode();
      setState(() {
        _started = ok;
        _unsupported = !ok;
      });
    });
  }

  @override
  void dispose() {
    // Leaving the screen resumes normal polling; session stats persist.
    if (_started) _controller?.stopDriveMode();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<AppController>();
    final s = c.driveSession;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Drive mode'),
        actions: [
          if (s != null && s.sampleCount > 0)
            IconButton(
              tooltip: 'Reset session',
              icon: const Icon(Icons.refresh),
              onPressed: c.resetDriveSession,
            ),
        ],
      ),
      body: _unsupported
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Drive mode needs a live pack-current signal — connect to a '
                  'vehicle whose signal set includes one (Cadillac Lyriq, or '
                  'demo mode).',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : s == null || s.sampleCount == 0
              ? const Center(child: CircularProgressIndicator())
              : _DriveBody(session: s),
    );
  }
}

class _DriveBody extends StatelessWidget {
  final DriveSession session;
  const _DriveBody({required this.session});

  @override
  Widget build(BuildContext context) {
    final kw = session.currentKw ?? 0;
    final regen = kw < -0.5;
    final draw = kw > 0.5;
    final color = regen
        ? Colors.green
        : draw
            ? Colors.deepOrange
            : Theme.of(context).colorScheme.onSurfaceVariant;
    final label = regen
        ? 'REGEN'
        : draw
            ? 'POWER'
            : 'IDLE';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Center(
          child: Column(
            children: [
              Text(label,
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(color: color, letterSpacing: 2)),
              Text(
                kw.abs().toStringAsFixed(1),
                style: Theme.of(context)
                    .textTheme
                    .displayLarge
                    ?.copyWith(fontWeight: FontWeight.w700, color: color),
              ),
              Text('kW', style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _PowerBar(kw: kw, session: session),
        const SizedBox(height: 16),
        SizedBox(
          height: 160,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: CustomPaint(
                painter: _PowerGraphPainter(
                  samples: session.recent,
                  window: session.window,
                  lineColor: Theme.of(context).colorScheme.primary,
                  zeroColor: Theme.of(context).colorScheme.outlineVariant,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                _row(context, 'Peak power',
                    '${session.peakDrawKw.toStringAsFixed(1)} kW'),
                _row(context, 'Peak regen',
                    '${session.peakRegenKw.toStringAsFixed(1)} kW'),
                _row(context, 'Energy used',
                    '${session.energyUsedKwh.toStringAsFixed(2)} kWh'),
                _row(context, 'Energy recovered',
                    '${session.energyRecoveredKwh.toStringAsFixed(2)} kWh'),
                _row(context, 'Duration', _fmtDuration(session.duration)),
                _row(context, 'Sample rate',
                    '${session.sampleRateHz.toStringAsFixed(1)} Hz'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Polling pack current only, as fast as the adapter allows. Other '
          'dashboard signals pause while drive mode is open.',
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _row(BuildContext context, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label),
            Text(value,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontFamily: 'monospace')),
          ],
        ),
      );

  static String _fmtDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m}m ${s.toString().padLeft(2, '0')}s';
  }
}

/// Horizontal centered-zero bar: regen extends left (green), draw extends
/// right (orange). Scale auto-grows with the session's peaks (min ±50 kW).
class _PowerBar extends StatelessWidget {
  final double kw;
  final DriveSession session;
  const _PowerBar({required this.kw, required this.session});

  @override
  Widget build(BuildContext context) {
    final scale = math.max(
        50.0, math.max(session.peakDrawKw, session.peakRegenKw) * 1.15);
    final frac = (kw / scale).clamp(-1.0, 1.0);
    return SizedBox(
      height: 26,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final half = constraints.maxWidth / 2;
          return Stack(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(13),
                ),
              ),
              Positioned(
                left: frac < 0 ? half * (1 + frac) : half,
                width: half * frac.abs(),
                top: 0,
                bottom: 0,
                child: Container(
                  decoration: BoxDecoration(
                    color: frac < 0 ? Colors.green : Colors.deepOrange,
                    borderRadius: BorderRadius.circular(13),
                  ),
                ),
              ),
              Positioned(
                left: half - 1,
                width: 2,
                top: 0,
                bottom: 0,
                child: ColoredBox(
                    color: Theme.of(context).colorScheme.outline),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PowerGraphPainter extends CustomPainter {
  final List<PowerSample> samples;
  final Duration window;
  final Color lineColor;
  final Color zeroColor;

  _PowerGraphPainter({
    required this.samples,
    required this.window,
    required this.lineColor,
    required this.zeroColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2) return;

    var maxAbs = 10.0;
    for (final s in samples) {
      if (s.kw.abs() > maxAbs) maxAbs = s.kw.abs();
    }
    maxAbs *= 1.1;

    final end = samples.last.t;
    final start = end.subtract(window);
    final spanMs = window.inMilliseconds.toDouble();

    double x(DateTime t) =>
        (t.difference(start).inMilliseconds / spanMs) * size.width;
    double y(double kw) => size.height / 2 - (kw / maxAbs) * (size.height / 2);

    // Zero line.
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      Paint()
        ..color = zeroColor
        ..strokeWidth = 1,
    );

    final path = Path()..moveTo(x(samples.first.t), y(samples.first.kw));
    for (final s in samples.skip(1)) {
      path.lineTo(x(s.t), y(s.kw));
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = lineColor
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_PowerGraphPainter old) => true;
}
