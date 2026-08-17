import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app/app_controller.dart';
import '../transport/elm_ble_source.dart';

/// Raw ELM327 terminal: send arbitrary AT/OBD commands and see exactly what the
/// adapter returns. This is the first thing to reach for when the dashboard is
/// silent — it distinguishes "adapter not responding" from "adapter fine, car
/// not answering" from "wrong protocol".
class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _Entry {
  final String cmd;
  final String response;
  final bool failed;
  _Entry(this.cmd, this.response, {this.failed = false});
}

class _TerminalScreenState extends State<TerminalScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<_Entry> _log = [];
  bool _busy = false;

  /// Ordered probe that answers "can we talk to this car at all?".
  /// ATZ/ATE0/ATI prove the adapter responds; ATDPN reports the negotiated
  /// protocol; 0100 is the standard "which PIDs do you support" request — if
  /// that answers, the vehicle bus is genuinely reachable.
  static const _handshake = <String>[
    'ATZ', 'ATE0', 'ATL0', 'ATS0', 'ATH1', 'ATSP0',
    'ATI', 'ATRV', 'ATDPN', '0100', '010C', '010D', '0142',
  ];

  Future<void> _send(String cmd) async {
    final c = context.read<AppController>();
    final source = c.activeSource;
    if (source == null) {
      setState(() => _log.add(_Entry(cmd, 'not connected', failed: true)));
      return;
    }
    setState(() => _busy = true);
    try {
      final resp = await source.send(cmd, timeout: const Duration(seconds: 6));
      setState(() => _log.add(_Entry(cmd, resp.trim())));
    } catch (e) {
      setState(() => _log.add(_Entry(cmd, '$e', failed: true)));
    } finally {
      setState(() => _busy = false);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    }
  }

  Future<void> _runHandshake() async {
    for (final cmd in _handshake) {
      if (!mounted) return;
      await _send(cmd);
    }
  }

  String _transcript() => _log
      .map((e) => '>>> ${e.cmd}\n${e.response}')
      .join('\n\n');

  @override
  Widget build(BuildContext context) {
    final c = context.watch<AppController>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Adapter terminal'),
        actions: [
          if (c.activeSource is ElmBleSource)
            IconButton(
              tooltip: 'BLE diagnostics',
              icon: const Icon(Icons.bluetooth_searching),
              onPressed: () => setState(() => _log.add(_Entry(
                    'BLE diagnostics',
                    (c.activeSource as ElmBleSource).diagnosticsDump(),
                  ))),
            ),
          if (_log.isNotEmpty) ...[
            IconButton(
              tooltip: 'Share transcript',
              icon: const Icon(Icons.share),
              onPressed: () => Share.share(_transcript(),
                  subject: 'OBD terminal transcript'),
            ),
            IconButton(
              tooltip: 'Clear',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => setState(_log.clear),
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    c.activeSource == null
                        ? 'Not connected — connect an adapter first.'
                        : 'Connected: ${c.activeSource!.name}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                FilledButton.icon(
                  onPressed:
                      _busy || c.activeSource == null ? null : _runHandshake,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Run handshake'),
                ),
              ],
            ),
          ),
          const Divider(height: 16),
          Expanded(
            child: _log.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Tap "Run handshake" to check the adapter and the '
                        'vehicle bus:\n\n'
                        'ATI / ATRV → adapter alive, battery voltage\n'
                        'ATDPN → negotiated OBD protocol\n'
                        '0100 → vehicle answers (bus reachable)\n\n'
                        'Or type any command below.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: _log.length,
                    itemBuilder: (_, i) {
                      final e = _log[i];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('>>> ${e.cmd}',
                                style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12)),
                            SelectableText(
                              e.response.isEmpty ? '(empty)' : e.response,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                color: e.failed
                                    ? Theme.of(context).colorScheme.error
                                    : null,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      autocorrect: false,
                      enableSuggestions: false,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        labelText: 'Command (e.g. 0100, ATDPN)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (v) {
                        if (v.trim().isEmpty) return;
                        _send(v.trim());
                        _input.clear();
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _busy || c.activeSource == null
                        ? null
                        : () {
                            final v = _input.text.trim();
                            if (v.isEmpty) return;
                            _send(v);
                            _input.clear();
                          },
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }
}
