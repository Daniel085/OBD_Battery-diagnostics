import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app/app_controller.dart';
import '../engine/capacity_test.dart';

/// The charge-session capacity test: coulomb-count a charge between two
/// dash-read SOC endpoints and derive measured pack capacity + SOH.
///
/// Works with intermittent connections by design — connect briefly at charge
/// start, occasionally during, and at the end; the session persists across
/// app restarts and the engine interpolates the gaps with honest error bars.
class CapacityScreen extends StatefulWidget {
  const CapacityScreen({super.key});

  @override
  State<CapacityScreen> createState() => _CapacityScreenState();
}

class _CapacityScreenState extends State<CapacityScreen> {
  final _socStart = TextEditingController();
  final _socEnd = TextEditingController();
  final _shareKey = GlobalKey();

  /// Render the results card to a PNG and hand it to the share sheet — the
  /// artifact a user posts to a forum or sends to a buyer.
  Future<void> _shareResultImage() async {
    final boundary = _shareKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;
    if (boundary == null) return;
    final image = await boundary.toImage(pixelRatio: 3.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return;
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/capacity_result.png');
    await file.writeAsBytes(bytes.buffer.asUint8List());
    await Share.shareXFiles(
      [XFile(file.path)],
      text: 'EV battery capacity measured with OBD Battery Diagnostics',
    );
  }

  @override
  void initState() {
    super.initState();
    final t = context.read<AppController>().capacityTest;
    if (t?.socStartPct != null) {
      _socStart.text = t!.socStartPct!.toStringAsFixed(0);
    }
    if (t?.socEndPct != null) _socEnd.text = t!.socEndPct!.toStringAsFixed(0);
  }

  @override
  void dispose() {
    _socStart.dispose();
    _socEnd.dispose();
    super.dispose();
  }

  void _applySoc(AppController c) {
    c.setCapacitySoc(
      start: double.tryParse(_socStart.text),
      end: double.tryParse(_socEnd.text),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<AppController>();
    final test = c.capacityTest;
    return Scaffold(
      appBar: AppBar(title: const Text('Capacity test')),
      body: test == null ? _intro(c) : _session(c, test),
    );
  }

  Widget _intro(AppController c) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Measures usable pack capacity by integrating pack current over '
              'a charge session (coulomb counting), then scales by the dash '
              'SOC change to estimate full-pack capacity and state of health.\n\n'
              'How to run it:\n'
              '1. Note the dash SOC %, start the test, plug in.\n'
              '2. Connect the app now and then during the charge — a steady '
              'AC charge doesn\'t need continuous sampling. Best accuracy: '
              'let the charge run to its target cutoff.\n'
              '3. When charging stops, connect once more, enter the final '
              'dash SOC, and finish the test.\n\n'
              'The session survives app restarts and disconnects.',
            ),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () => c.startCapacityTest(),
          icon: const Icon(Icons.play_arrow),
          label: const Text('Start capacity test'),
        ),
      ],
    );
  }

  Widget _session(AppController c, CapacityTestSession test) {
    final a = test.analyze();
    final live = c.latest['HVBAT_CURRENT'];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _statusCard(test, a, live),
        const SizedBox(height: 12),
        RepaintBoundary(key: _shareKey, child: _resultsCard(test, a)),
        if (a.sohPct != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton.icon(
              onPressed: _shareResultImage,
              icon: const Icon(Icons.ios_share),
              label: const Text('Share result'),
            ),
          ),
        const SizedBox(height: 12),
        _socCard(c),
        if (a.segments.isNotEmpty) ...[
          const SizedBox(height: 12),
          _segmentsCard(a),
        ],
        const SizedBox(height: 16),
        if (!test.isFinished)
          FilledButton.icon(
            onPressed: () {
              _applySoc(c);
              c.finishCapacityTest();
            },
            icon: const Icon(Icons.flag),
            label: const Text('Finish test'),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Discard capacity test?'),
                content: const Text(
                    'All recorded samples for this session will be deleted.'),
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
            if (ok == true) c.discardCapacityTest();
          },
          icon: const Icon(Icons.delete_outline),
          label: Text(test.isFinished ? 'Discard result' : 'Discard test'),
        ),
      ],
    );
  }

  Widget _statusCard(CapacityTestSession test, CapacityAnalysis a, live) {
    final (icon, label) = test.isFinished
        ? (Icons.flag, 'Finished')
        : a.chargingNow
            ? (Icons.bolt, 'Charging — ${a.segments.last.meanAmps.abs().toStringAsFixed(1)} A avg')
            : (Icons.hourglass_empty, 'Waiting for charge current');
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(label),
        subtitle: Text([
          'started ${_fmtTime(test.startedAt)}',
          if (live != null)
            'live: ${live.value.toStringAsFixed(1)} A',
          '${test.samples.length} samples',
        ].join(' · ')),
      ),
    );
  }

  Widget _resultsCard(CapacityTestSession test, CapacityAnalysis a) {
    final soh = a.sohPct;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (soh != null) ...[
              Text('State of health',
                  style: Theme.of(context).textTheme.labelLarge),
              Text('${soh.toStringAsFixed(1)} %',
                  style: Theme.of(context).textTheme.displaySmall),
              Text(
                  '${a.packKwh!.toStringAsFixed(1)} kWh '
                  '(${a.packAh!.toStringAsFixed(0)} Ah) full-pack estimate',
                  style: Theme.of(context).textTheme.bodyMedium),
              const Divider(height: 24),
            ],
            _metricRow('Charge counted',
                '${a.chargedAh.toStringAsFixed(1)} ± ${a.errAh.toStringAsFixed(1)} Ah'),
            _metricRow('Energy (at nominal V)',
                '${a.chargedKwh.toStringAsFixed(1)} kWh'),
            _metricRow('Sampling coverage',
                '${(a.coverage * 100).toStringAsFixed(0)} %'),
            if (a.largestGap > Duration.zero)
              _metricRow('Largest gap', _fmtDuration(a.largestGap)),
            if (soh == null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Enter both dash SOC endpoints below to get capacity and SOH.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            // Footer so the shared PNG stands alone (who measured it, when).
            const Divider(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('OBD Battery Diagnostics',
                    style: Theme.of(context).textTheme.bodySmall),
                Text(
                  _fmtDate(test.finishedAt ?? DateTime.now()),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _fmtDate(DateTime t) {
    final l = t.toLocal();
    return '${l.year}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')}';
  }

  Widget _socCard(AppController c) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Dash SOC endpoints',
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            Text(
              'Read from the instrument cluster — charge-cutoff values are the '
              'trustworthy ones; mid-charge readings lag.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _socStart,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Start %',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (_) => _applySoc(c),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _socEnd,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'End %',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (_) => _applySoc(c),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _segmentsCard(CapacityAnalysis a) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Charge segments',
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            for (final s in a.segments)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '${_fmtTime(s.start)}–${_fmtTime(s.end)}  '
                  '${s.ah.toStringAsFixed(1)} Ah @ '
                  '${s.meanAmps.abs().toStringAsFixed(1)} A '
                  '(${s.sampleCount} samples)',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _metricRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      );

  static String _fmtTime(DateTime t) {
    final l = t.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }

  static String _fmtDuration(Duration d) => d.inHours > 0
      ? '${d.inHours}h ${d.inMinutes % 60}m'
      : '${d.inMinutes}m ${d.inSeconds % 60}s';
}
