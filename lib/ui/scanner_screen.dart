import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/app_controller.dart';
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
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.read<AppController>();
    return Scaffold(
      appBar: AppBar(title: const Text('DID Scanner (reverse engineering)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Sweeps UDS service 0x22 across a DID range on the target ECU and '
            'lists responders. Read-only. Run with the vehicle stationary.',
            style: TextStyle(fontSize: 13),
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
