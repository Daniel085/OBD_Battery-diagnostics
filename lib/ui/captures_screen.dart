import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app/app_controller.dart';

/// The captures kept on this phone (session recordings, signal-check reports,
/// DID sweeps), newest first, with a way to send them on.
class CapturesScreen extends StatefulWidget {
  const CapturesScreen({super.key});

  @override
  State<CapturesScreen> createState() => _CapturesScreenState();
}

class _CapturesScreenState extends State<CapturesScreen> {
  List<(File, int)>? _files;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = context.read<AppController>();
    await c.flushRecording();
    final files = await c.captureStore?.list() ?? const <File>[];
    final sized = <(File, int)>[];
    for (final f in files) {
      try {
        sized.add((f, await f.length()));
      } on IOException {
        // Deleted meanwhile.
      }
    }
    if (mounted) setState(() => _files = sized);
  }

  Future<void> _share(List<File> files) async {
    await context.read<AppController>().flushRecording();
    await Share.shareXFiles([for (final f in files) XFile(f.path)],
        subject: 'OBD captures');
  }

  static String _name(File f) => f.uri.pathSegments.last;

  static String _size(int bytes) => bytes < 1024
      ? '$bytes B'
      : bytes < 1024 * 1024
          ? '${(bytes / 1024).toStringAsFixed(0)} KB'
          : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

  /// "20261116-140502_Ford-F-150-Hybrid-2021_session.txt" in words.
  static (String, String) _describe(String name) {
    final m =
        RegExp(r'^(\d{4})(\d\d)(\d\d)-(\d\d)(\d\d)\d\d_(.+)_([a-z]+)\.txt$')
            .firstMatch(name);
    if (m == null) return (name, '');
    final kind = switch (m.group(7)) {
      'session' => 'Session recording',
      'check' => 'Signal check',
      'scan' => 'DID sweep',
      final other => other!,
    };
    return (
      kind,
      '${m.group(6)}\n${m.group(1)}-${m.group(2)}-${m.group(3)} '
          '${m.group(4)}:${m.group(5)}'
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<AppController>();
    final files = _files;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Captures'),
        actions: [
          if (files != null && files.isNotEmpty)
            IconButton(
              tooltip: 'Share all',
              icon: const Icon(Icons.ios_share),
              onPressed: () => _share([for (final (f, _) in files) f]),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Every session with a real adapter is recorded here as it '
            'happens: each request and the raw reply. Signal checks and DID '
            'sweeps are saved too. The files stay on this phone until you '
            'share or delete them; the oldest are removed automatically.',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 8),
          if (files == null)
            const Center(child: CircularProgressIndicator())
          else if (files.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 24),
              child: Text('Nothing recorded yet. Demo sessions are not kept.'),
            )
          else
            for (final (file, bytes) in files)
              Builder(builder: (context) {
                final name = _name(file);
                final (kind, detail) = _describe(name);
                final live = name == c.recordingName;
                return Card(
                  child: ListTile(
                    leading: Icon(live
                        ? Icons.fiber_manual_record
                        : Icons.description_outlined),
                    iconColor: live ? Colors.red : null,
                    title: Text(live ? '$kind (recording now)' : kind),
                    subtitle: Text('$detail · ${_size(bytes)}'),
                    isThreeLine: true,
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        tooltip: 'Share',
                        icon: const Icon(Icons.share),
                        onPressed: () => _share([file]),
                      ),
                      if (!live)
                        IconButton(
                          tooltip: 'Delete',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            await c.captureStore?.delete(file);
                            await _load();
                          },
                        ),
                    ]),
                  ),
                );
              }),
        ],
      ),
    );
  }
}
