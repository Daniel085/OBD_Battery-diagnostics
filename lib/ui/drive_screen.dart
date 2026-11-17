import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app/app_controller.dart';
import '../engine/diagnostics_client.dart';
import '../engine/display_units.dart';
import '../engine/drive_record.dart';
import '../engine/drive_session.dart';

/// Drive mode: a live EV power meter. The poll loop switches to hammering the
/// pack-current DID (~5-15 Hz on a real adapter), showing instantaneous
/// kW draw/regen, a rolling power graph, and per-session energy stats —
/// the "Scan My Tesla" view for Ultium, over a generic BLE adapter. Vehicles
/// whose signal set has motor signals also get a gauge card for them,
/// refreshed every few seconds.
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
              : Column(
                  children: [
                    _RecordBar(controller: c),
                    Expanded(child: _DriveBody(session: s, controller: c)),
                  ],
                ),
    );
  }
}

/// Record / Finish / Share controls for the Drive Health Report.
class _RecordBar extends StatelessWidget {
  final AppController controller;
  const _RecordBar({required this.controller});

  Future<void> _shareReport(BuildContext context, DriveRecord rec) async {
    await Share.share(rec.reportText(units: controller.units),
        subject: 'EV Drive Health Report');
  }

  @override
  Widget build(BuildContext context) {
    final rec = controller.driveRecord;
    final recording = controller.isRecordingDrive;
    final cs = Theme.of(context).colorScheme;

    if (rec == null) {
      return Material(
        color: cs.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Record a drive to capture a shareable battery health report.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              FilledButton.icon(
                onPressed: controller.startDriveRecording,
                icon: const Icon(Icons.fiber_manual_record, size: 18),
                label: const Text('Record'),
              ),
            ],
          ),
        ),
      );
    }

    return Material(
      color: recording ? cs.errorContainer : cs.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(recording ? Icons.fiber_manual_record : Icons.check_circle,
                size: 18,
                color: recording ? cs.error : cs.onSecondaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                recording
                    ? 'Recording · ${rec.ticks.length} samples'
                    : 'Drive recorded · ${rec.ticks.length} samples',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            if (recording)
              FilledButton.icon(
                onPressed: controller.finishDriveRecording,
                icon: const Icon(Icons.stop, size: 18),
                label: const Text('Finish'),
              )
            else ...[
              TextButton(
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Discard drive?'),
                      content: const Text('The recorded report will be deleted.'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Cancel')),
                        FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Discard')),
                      ],
                    ),
                  );
                  if (ok == true) controller.discardDriveRecording();
                },
                child: const Text('Discard'),
              ),
              FilledButton.icon(
                onPressed: () => _shareReport(context, rec),
                icon: const Icon(Icons.ios_share, size: 18),
                label: const Text('Share'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DriveBody extends StatelessWidget {
  final DriveSession session;
  final AppController controller;
  const _DriveBody({required this.session, required this.controller});

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
        if (controller.hasDriveExtras) ...[
          const SizedBox(height: 8),
          _MotorCard(controller: controller),
        ],
        const SizedBox(height: 8),
        Text(
          controller.hasDriveExtras
              ? 'Pack current is polled as fast as the adapter allows. Motor '
                  'values refresh every few seconds, and the power feed '
                  'pauses while they are read. Other dashboard signals pause '
                  'while drive mode is open.'
              : 'Polling pack current only, as fast as the adapter allows. '
                  'Other dashboard signals pause while drive mode is open.',
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

/// Motor temperature, speed and torque as dial gauges, for vehicles whose
/// signal set has them. Values a signal set marks unverified (unit ending in
/// `?`) are shown as read, with a note.
class _MotorCard extends StatelessWidget {
  final AppController controller;
  const _MotorCard({required this.controller});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final readings = controller.driveExtraReadings;
    final unverified = readings.any((r) => r.unit.endsWith('?'));
    final now = DateTime.now();
    // Older than this and a gauge is dimmed: the value is no longer live.
    final stale = controller.driveExtrasSpacing * 4;

    Widget body;
    if (readings.isEmpty) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          controller.driveExtrasResponding
              ? 'Waiting for motor data…'
              : 'This vehicle did not answer the motor requests.',
          style: text.bodyMedium,
          textAlign: TextAlign.center,
        ),
      );
    } else {
      body = LayoutBuilder(builder: (context, constraints) {
        // Three dials to a row on a phone, two when that would be cramped.
        const gap = 8.0;
        final perRow = constraints.maxWidth >= 3 * 96 + 2 * gap ? 3 : 2;
        final size = math.min(
            150.0, (constraints.maxWidth - gap * (perRow - 1)) / perRow);
        return Wrap(
          alignment: WrapAlignment.center,
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final r in readings)
              Opacity(
                opacity: now.difference(r.timestamp) > stale ? 0.4 : 1,
                child: _DialGauge(
                    reading: r, units: controller.units, size: size),
              ),
          ],
        );
      });
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Motor', style: text.titleMedium),
            const SizedBox(height: 8),
            body,
            if (readings.isNotEmpty && !controller.driveExtrasResponding) ...[
              const SizedBox(height: 8),
              Text('Motor requests stopped answering; values are not live.',
                  style: text.bodySmall, textAlign: TextAlign.center),
            ],
            if (unverified) ...[
              const SizedBox(height: 8),
              Text(
                'Values marked ? use a decoding that has not been confirmed '
                'on this vehicle yet.',
                style: text.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One reading on a 270° dial. The arc spans the signal's expected range
/// (`min`..`max` in the signal set). A range symmetric about zero (torque)
/// fills from the centre outwards, orange above zero and green below, like
/// the power bar; any other range fills from its low end. Without a range
/// the dial shows the number only.
class _DialGauge extends StatelessWidget {
  final Reading reading;
  final DisplayUnits units;
  final double size;
  const _DialGauge(
      {required this.reading, required this.units, required this.size});

  /// The signal name without its trailing "(...)" qualifier.
  static String _label(String name) =>
      name.replaceFirst(RegExp(r'\s*\([^)]*\)\s*$'), '');

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final unit = reading.unit;
    final min = reading.signal.fmt.min?.toDouble();
    final max = reading.signal.fmt.max?.toDouble();
    final hasRange = min != null && max != null && max > min;
    final centred = hasRange && min == -max;
    final value = units.convert(unit, reading.value);
    // Wide-range dials (rpm, torque) read better without decimals.
    final decimals = hasRange && max - min >= 500 ? 0 : 1;

    return SizedBox(
      width: size,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: CustomPaint(
              painter: _DialPainter(
                value: reading.value,
                min: hasRange ? min : null,
                max: hasRange ? max : null,
                track: cs.surfaceContainerHighest,
                centred: centred,
                fill: !centred
                    ? cs.primary
                    : reading.value < 0
                        ? Colors.green
                        : Colors.deepOrange,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        value.toStringAsFixed(decimals),
                        style: text.headlineMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Text(units.symbolFor(unit), style: text.bodyMedium),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _label(reading.signal.name),
            style: text.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  final double value;
  final double? min;
  final double? max;
  final bool centred;
  final Color track;
  final Color fill;

  _DialPainter({
    required this.value,
    required this.min,
    required this.max,
    required this.centred,
    required this.track,
    required this.fill,
  });

  static const _start = math.pi * 0.75; // lower left
  static const _sweep = math.pi * 1.5; // 270°, gap at the bottom

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 8.0;
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: size.shortestSide / 2 - stroke,
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, _start, _sweep, false, paint..color = track);

    final lo = min, hi = max;
    if (lo == null || hi == null) return;
    double frac(double v) => ((v - lo) / (hi - lo)).clamp(0.0, 1.0);
    final from = frac(centred ? 0 : lo);
    final to = frac(value);
    if ((to - from).abs() < 1e-6) return;
    canvas.drawArc(rect, _start + _sweep * math.min(from, to),
        _sweep * (to - from).abs(), false, paint..color = fill);
  }

  @override
  bool shouldRepaint(_DialPainter old) =>
      old.value != value ||
      old.min != min ||
      old.max != max ||
      old.centred != centred ||
      old.track != track ||
      old.fill != fill;
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
