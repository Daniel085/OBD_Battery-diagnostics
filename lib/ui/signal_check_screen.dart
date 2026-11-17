import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app/app_controller.dart';
import '../engine/signal_set.dart';
import '../tools/signal_check.dart';

/// Sends every request of the connected vehicle's signal set once and lists
/// what the vehicle did with each. The shared report is the record to bring
/// back from a first session with a vehicle nobody has read yet.
class SignalCheckScreen extends StatefulWidget {
  const SignalCheckScreen({super.key});

  @override
  State<SignalCheckScreen> createState() => _SignalCheckScreenState();
}

class _SignalCheckScreenState extends State<SignalCheckScreen> {
  final List<CommandCheck> _checks = [];
  Map<String, String> _adapterInfo = const {};
  DateTime? _when;
  bool _running = false;
  bool _stop = false;
  String? _error;

  /// File the last report was saved to on this phone, if it was.
  String? _savedAs;

  Future<void> _run(AppController c, SignalSet set) async {
    setState(() {
      _checks.clear();
      _running = true;
      _stop = false;
      _error = null;
      _savedAs = null;
      _when = DateTime.now();
    });
    // Kept apart from the widget's state so the report is saved even if the
    // screen is closed while the check runs.
    final when = _when!;
    final done = <CommandCheck>[];
    var info = const <String, String>{};
    final adapter = c.activeSource?.name ?? '';
    c.captureNote('signal check started');
    try {
      await c.withAdapter((source) async {
        info = await SignalCheck.adapterInfo(source);
        _adapterInfo = info;
        await SignalCheck.run(
          source,
          set,
          shouldStop: () => _stop,
          onResult: (check) {
            done.add(check);
            if (mounted) setState(() => _checks.add(check));
          },
        );
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Check stopped: $e');
    } finally {
      c.captureNote('signal check ended, ${done.length} requests');
      final saved = done.isEmpty
          ? null
          : await c.saveCapture(
              'check',
              SignalCheck.report(done,
                  set: set, when: when, adapter: adapter, adapterInfo: info));
      if (mounted) {
        setState(() {
          _running = false;
          _savedAs = saved;
        });
      }
    }
  }

  String _report(AppController c, SignalSet set) => SignalCheck.report(
        _checks,
        set: set,
        when: _when ?? DateTime.now(),
        adapter: c.activeSource?.name ?? '',
        adapterInfo: _adapterInfo,
      );

  @override
  void dispose() {
    _stop = true;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.read<AppController>();
    final set = c.signalSet;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    int count(CheckStatus s) => _checks.where((x) => x.status == s).length;

    final rows = <Widget>[];
    String? section;
    for (final check in _checks) {
      final title = SignalCheck.sectionTitle(check.command);
      if (title != section) {
        section = title;
        rows.add(Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 4),
          child: Text('Control unit $title', style: text.titleSmall),
        ));
      }
      rows.add(_CheckRow(check: check));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Signal check'),
        actions: [
          if (_checks.isNotEmpty && !_running && set != null)
            IconButton(
              tooltip: 'Share report',
              icon: const Icon(Icons.share),
              onPressed: () => Share.share(_report(c, set),
                  subject: 'Signal check ${set.vehicle}'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Sends every request this vehicle\'s signal set knows, once, and '
            'lists which ones the vehicle answered. Read-only. Dashboard '
            'readings pause while it runs. Share the report afterwards: it '
            'holds the raw replies.',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          if (set == null)
            const Text('Connect an adapter (or demo) first.')
          else if (_running)
            OutlinedButton.icon(
              onPressed: () => setState(() => _stop = true),
              icon: const Icon(Icons.stop),
              label: Text('Stop (${_checks.length} of ${set.commands.length})'),
            )
          else
            FilledButton.icon(
              onPressed: () => _run(c, set),
              icon: const Icon(Icons.fact_check),
              label: Text('Check ${set.commands.length} requests'),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: TextStyle(color: scheme.error)),
            ),
          if (_savedAs != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Saved on this phone (Captures): $_savedAs',
                  style: text.bodySmall),
            ),
          if (_checks.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                '${count(CheckStatus.answered)} answered, '
                '${count(CheckStatus.rejected)} rejected, '
                '${count(CheckStatus.silent)} silent'
                '${count(CheckStatus.failed) == 0 ? '' : ', ${count(CheckStatus.failed)} failed'}',
                style: text.titleMedium,
              ),
            ),
          ...rows,
        ],
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  final CommandCheck check;
  const _CheckRow({required this.check});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, colour, verdict) = switch (check.status) {
      CheckStatus.answered => (Icons.check_circle, Colors.green, 'answered'),
      CheckStatus.rejected => (
          Icons.block,
          scheme.error,
          'rejected (code ${check.nrc!.toRadixString(16).toUpperCase()})'
        ),
      CheckStatus.silent => (
          Icons.remove_circle_outline,
          scheme.outline,
          'no reply'
        ),
      CheckStatus.failed => (
          Icons.error_outline,
          scheme.error,
          check.detail ?? 'failed'
        ),
    };
    final names = check.command.signals.map((s) => s.name).join(', ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: colour, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(names, style: Theme.of(context).textTheme.bodyMedium),
                Text(
                  '${check.request}  $verdict'
                  '${check.raw.isEmpty || check.status == CheckStatus.silent ? '' : '\n${check.raw}'}',
                  style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
