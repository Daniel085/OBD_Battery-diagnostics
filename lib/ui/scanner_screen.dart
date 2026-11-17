import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app/app_controller.dart';
import '../engine/signal_set.dart';
import '../tools/uds_scanner.dart';

/// In-app surface for the reverse-engineering DID scanner (Phase 5). Sweeps a
/// UDS 0x22 DID range on a target ECU and lists responders. Read-only.
class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  final _hdr = TextEditingController(text: '6F1');
  final _rax = TextEditingController(text: '607');
  final _eax = TextEditingController(text: '07');
  final _start = TextEditingController(text: 'DD00');
  final _end = TextEditingController(text: 'DD10');
  bool _is29 = false;

  final List<DidScanResult> _hits = [];
  int _probed = 0;
  int _total = 0;
  bool _running = false;
  String? _error;

  /// File the last sweep was saved to on this phone, if it was.
  String? _savedAs;

  void _applyPreset({
    required String hdr,
    required String rax,
    required String eax,
    required bool is29,
    required String start,
    required String end,
  }) {
    setState(() {
      _hdr.text = hdr;
      _rax.text = rax;
      _eax.text = eax;
      _is29 = is29;
      _start.text = start;
      _end.text = end;
    });
  }

  /// Self-documenting CSV of a sweep: the header records the addressing used
  /// so a saved result can be reproduced later.
  List<String> _csvHeader() => [
        '# DID scan',
        '# tester_hdr,${_hdr.text}',
        '# response_filter,${_rax.text}',
        '# ext_addr,${_eax.text}',
        '# can_29bit,$_is29',
        '# range,${_start.text}-${_end.text}',
      ];

  static String _csv(List<String> header, List<DidScanResult> hits,
      {int? probed}) {
    final rows = <String>[
      ...header,
      if (probed != null) '# probed,$probed',
      'did,bytes,hex',
    ];
    for (final h in hits) {
      final hex =
          h.data?.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ') ??
              '';
      rows.add('${h.didHex},${h.data?.length ?? 0},$hex');
    }
    return rows.join('\n');
  }

  String _resultsCsv() => _csv(_csvHeader(), _hits);

  Future<void> _run(AppController c) async {
    final source = c.activeSource;
    if (source == null) {
      setState(() => _error = 'Connect an adapter (or demo) first.');
      return;
    }
    final start = int.tryParse(_start.text.trim(), radix: 16);
    final end = int.tryParse(_end.text.trim(), radix: 16);
    if (start == null || end == null || start > end) {
      setState(() => _error = 'Invalid DID range.');
      return;
    }
    setState(() {
      _error = null;
      _running = true;
      _hits.clear();
      _probed = 0;
      _total = end - start + 1;
    });

    // Kept apart from the widget's state so the result is saved even if the
    // screen is closed during the sweep. (Every probe is also in the session
    // recording as it happens.)
    final found = <DidScanResult>[];
    var probed = 0;
    c.captureNote('DID sweep started: hdr ${_hdr.text} filter ${_rax.text} '
        'ext ${_eax.text} range ${_start.text}-${_end.text}');
    // The addressing as it is now: the fields can be edited during a sweep.
    final header = _csvHeader();
    await c.holdAdapter();
    final scanner = UdsScanner(
      source: source,
      requestHeader: _hdr.text.trim(),
      responseFilter: _rax.text.trim().isEmpty ? null : _rax.text.trim(),
      extendedAddress:
          _eax.text.trim().isEmpty ? null : int.parse(_eax.text.trim(), radix: 16),
      is29Bit: _is29,
    );

    try {
      await scanner.sweep(
        startDid: start,
        endDid: end,
        onResult: (r) {
          probed++;
          if (r.isInteresting) found.add(r);
          if (!mounted) return;
          setState(() {
            _probed++;
            if (r.isInteresting) _hits.add(r);
          });
        },
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'Scan error: $e');
    } finally {
      c.releaseAdapter();
      c.captureNote('DID sweep ended: $probed probed, ${found.length} answered');
      final saved = probed == 0
          ? null
          : await c.saveCapture('scan', _csv(header, found, probed: probed));
      if (mounted) {
        setState(() {
          _running = false;
          _savedAs = saved;
        });
      }
    }
  }

  /// One preset per control unit of the connected vehicle's signal set,
  /// covering the identifier blocks (xx00-xxFF) its known requests fall in.
  List<Widget> _vehiclePresets(SignalSet set) {
    final ranges = <(String, String?, String?), (int, int)>{};
    for (final cmd in set.commands) {
      if (cmd.hdr == null || cmd.service != '22' || cmd.payload.length != 4) {
        continue;
      }
      final did = int.parse(cmd.payload, radix: 16);
      final key = (cmd.hdr!, cmd.rax, cmd.eax);
      final (lo, hi) = ranges[key] ?? (did, did);
      ranges[key] = (did < lo ? did : lo, did > hi ? did : hi);
    }
    String hex4(int v) => v.toRadixString(16).padLeft(4, '0').toUpperCase();
    return [
      for (final MapEntry(key: (hdr, rax, eax), value: (lo, hi))
          in ranges.entries)
        ActionChip(
          label: Text('$hdr → ${rax ?? 'any'}${eax == null ? '' : ' ($eax)'}'),
          onPressed: () => _applyPreset(
              hdr: hdr,
              rax: rax ?? '',
              eax: eax ?? '',
              is29: set.protocol.canFormat == CanFormat.bits29,
              start: hex4(lo & 0xFF00),
              end: hex4(hi | 0xFF)),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final c = context.read<AppController>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('DID Scanner (reverse engineering)'),
        actions: [
          if (_hits.isNotEmpty)
            IconButton(
              tooltip: 'Share results',
              icon: const Icon(Icons.share),
              onPressed: () => Share.share(_resultsCsv(),
                  subject: 'DID scan ${_hdr.text} ${_start.text}-${_end.text}'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Sweeps UDS service 0x22 across a DID range on the target ECU and '
            'lists responders. Read-only. Run with the vehicle stationary. '
            'Dashboard readings pause during a sweep.',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 8),
          if (c.signalSet case final set?) ...[
            Text('Control units in ${set.vehicle}\'s signal set:',
                style: const TextStyle(fontSize: 12)),
            Wrap(spacing: 8, children: _vehiclePresets(set)),
            const SizedBox(height: 4),
            const Text('Other presets:', style: TextStyle(fontSize: 12)),
          ],
          Wrap(spacing: 8, children: [
            ActionChip(
              label: const Text('BMW SME'),
              onPressed: () => _applyPreset(
                  hdr: '6F1', rax: '607', eax: '07', is29: false,
                  start: 'DD00', end: 'DDFF'),
            ),
            ActionChip(
              label: const Text('GM Lyriq — discover ECUs'),
              onPressed: () => _applyPreset(
                  hdr: '18DB33F1', rax: '', eax: '', is29: true,
                  start: 'F190', end: 'F19F'),
            ),
            ActionChip(
              label: const Text('GM BECM (batt)'),
              onPressed: () => _applyPreset(
                  hdr: '18DA07F1', rax: '18DAF107', eax: '', is29: true,
                  start: '4000', end: '43FF'),
            ),
          ]),
          const SizedBox(height: 8),
          const Text(
            'GM 29-bit addressing: functional broadcast 18DB33F1 discovers which '
            'ECUs answer (their id is 18DAF1xx). Then target an ECU physically '
            'with 18DAxxF1 / filter 18DAF1xx. BECM (battery) is commonly 07; '
            'adjust xx to whatever answered.',
            style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _field(_hdr, 'Tester hdr')),
            const SizedBox(width: 8),
            Expanded(child: _field(_rax, 'Resp filter')),
            const SizedBox(width: 8),
            Expanded(child: _field(_eax, 'Ext addr')),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _field(_start, 'Start DID (hex)')),
            const SizedBox(width: 8),
            Expanded(child: _field(_end, 'End DID (hex)')),
          ]),
          SwitchListTile(
            value: _is29,
            onChanged: (v) => setState(() => _is29 = v),
            title: const Text('29-bit CAN (GM Ultium / Lyriq)'),
            contentPadding: EdgeInsets.zero,
          ),
          FilledButton.icon(
            onPressed: _running ? null : () => _run(c),
            icon: const Icon(Icons.search),
            label: Text(_running ? 'Scanning $_probed/$_total…' : 'Start sweep'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          if (_savedAs != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Saved on this phone (Captures): $_savedAs',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          const Divider(height: 32),
          Text('${_hits.length} responding DID(s)',
              style: Theme.of(context).textTheme.titleMedium),
          ..._hits.map((h) => Card(
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.memory),
                  title: Text('DID ${h.didHex}'),
                  subtitle: Text(h.data == null
                      ? ''
                      : '${h.data!.length} bytes: '
                          '${h.data!.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}'),
                ),
              )),
        ],
      ),
    );
  }

  Widget _field(TextEditingController ctrl, String label) => TextField(
        controller: ctrl,
        decoration: InputDecoration(
            labelText: label, border: const OutlineInputBorder(), isDense: true),
      );

  @override
  void dispose() {
    for (final c in [_hdr, _rax, _eax, _start, _end]) {
      c.dispose();
    }
    super.dispose();
  }
}
