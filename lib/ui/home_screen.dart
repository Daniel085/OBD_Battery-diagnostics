import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../app/app_controller.dart';
import '../app/signal_set_repository.dart';
import '../transport/simulated_source.dart';
import 'dashboard_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Future<void> _ensurePermissions() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<AppController>();
    return Scaffold(
      appBar: AppBar(title: const Text('OBD Battery Diagnostics')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('1. Select vehicle',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          RadioGroup<String>(
            groupValue: c.selectedVehicle?.id,
            onChanged: (id) {
              if (id == null) return;
              c.selectVehicle(SignalSetRepository.catalogue
                  .firstWhere((v) => v.id == id));
            },
            child: Column(
              children: SignalSetRepository.catalogue
                  .map((v) => RadioListTile<String>(
                        value: v.id,
                        title: Text(v.displayName),
                        subtitle: v.id.startsWith('Cadillac')
                            ? const Text(
                                'HV BMS not yet reverse-engineered — J1979 baseline only',
                                style: TextStyle(fontStyle: FontStyle.italic),
                              )
                            : null,
                      ))
                  .toList(),
            ),
          ),
          const Divider(height: 32),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('2. Connect adapter',
                  style: Theme.of(context).textTheme.titleMedium),
              FilledButton.icon(
                onPressed: () async {
                  await _ensurePermissions();
                  c.startScan();
                },
                icon: const Icon(Icons.bluetooth_searching),
                label: Text(c.phase == ConnectionPhase.scanning
                    ? 'Scanning…'
                    : 'Scan'),
              ),
            ],
          ),
          if (c.errorMessage != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: SelectableText(
                c.errorMessage!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          const SizedBox(height: 8),
          ...c.visibleDevices.map((d) => Card(
                // Stable key so Flutter reuses the row rather than rebuilding
                // it as the underlying advertisement data refreshes.
                key: ValueKey(d.id),
                child: ListTile(
                  leading: Icon(
                    Icons.bluetooth,
                    color: AppController.looksLikeObdName(d.name)
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  title: Text(d.name.isEmpty ? '(unnamed)' : d.name),
                  // Deliberately no RSSI here: it changes every packet and made
                  // the rows visibly churn.
                  subtitle: Text(d.id, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: c.selectedVehicle == null
                      ? null
                      : () async {
                          await c.connectAndStart(d);
                          if (context.mounted &&
                              c.phase == ConnectionPhase.polling) {
                            Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => const DashboardScreen()));
                          }
                        },
                ),
              )),
          if (c.discovered.isEmpty && c.phase == ConnectionPhase.scanning)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          const SizedBox(height: 24),
          const _AdapterHint(),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.play_circle_outline),
            label: const Text('Try demo mode (no adapter)'),
            onPressed: () async {
              final bmw = SignalSetRepository.catalogue
                  .firstWhere((v) => v.id == 'BMW-330e-2018');
              await c.connectWithSource(SimulatedBmwSource(), bmw);
              if (context.mounted && c.phase == ConnectionPhase.polling) {
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const DashboardScreen()));
              }
            },
          ),
        ],
      ),
    );
  }
}

class _AdapterHint extends StatelessWidget {
  const _AdapterHint();
  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Padding(
        padding: EdgeInsets.all(12),
        child: Text(
          'Tip: A generic ELM327 BLE clone works for the BMW 330e. For the '
          'Cadillac Lyriq (29-bit CAN), a genuine STN adapter (OBDLink CX/MX+) '
          'is strongly recommended — many clones cannot reach the Ultium '
          'battery data.',
          style: TextStyle(fontSize: 13),
        ),
      ),
    );
  }
}
