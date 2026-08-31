import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../app/app_controller.dart';
import '../app/signal_set_repository.dart';
import '../transport/data_source.dart';
import '../transport/simulated_source.dart';
import 'dashboard_screen.dart';
import 'onboarding_screen.dart';
import 'terminal_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Future<void> _startDemo(
      BuildContext context, AppController c, String vehicleId) async {
    final entry = SignalSetRepository.catalogue
        .firstWhere((v) => v.id == vehicleId);
    final DataSource source = vehicleId.startsWith('Cadillac')
        ? SimulatedLyriqSource()
        : SimulatedBmwSource();
    await c.connectWithSource(source, entry);
    if (context.mounted && c.phase == ConnectionPhase.polling) {
      Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const DashboardScreen()));
    }
  }

  Future<void> _ensurePermissions() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      // Location is an Android-only BLE-scan requirement (pre-Android-12
      // scanning is gated on it). Never ask for it on iOS — the prompt scares
      // users and iOS BLE doesn't need it.
      if (!kIsWeb && Platform.isAndroid) Permission.locationWhenInUse,
    ].request();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<AppController>();
    if (c.showOnboarding) {
      return OnboardingScreen(onDone: c.completeOnboarding);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('OBD Battery Diagnostics'),
        actions: [
          if (c.activeSource != null)
            IconButton(
              tooltip: 'Adapter terminal',
              icon: const Icon(Icons.terminal),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const TerminalScreen()),
              ),
            ),
        ],
      ),
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
                        subtitle: Text(
                          v.id.startsWith('Cadillac')
                              ? 'Pack current, temps, module voltages + '
                                  'capacity test — confirmed on-vehicle'
                              : 'Standard PIDs (SOC, temps) confirmed; '
                                  'BMS not reachable via the OBD port',
                          style: const TextStyle(fontStyle: FontStyle.italic),
                        ),
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
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                      child: Text(
                        c.errorMessage!,
                        style: TextStyle(
                          color:
                              Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                    if (c.errorDetails != null)
                      ExpansionTile(
                        title: const Text('Technical details',
                            style: TextStyle(fontSize: 13)),
                        dense: true,
                        shape: const Border(),
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: SelectableText(
                              c.errorDetails!,
                              style: const TextStyle(
                                  fontSize: 11, fontFamily: 'monospace'),
                            ),
                          ),
                        ],
                      ),
                  ],
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
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.play_circle_outline),
                  label: const Text('Demo: Lyriq'),
                  onPressed: () =>
                      _startDemo(context, c, 'Cadillac-Lyriq-2025'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.play_circle_outline),
                  label: const Text('Demo: BMW'),
                  onPressed: () => _startDemo(context, c, 'BMW-330e-2018'),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Demo mode needs no adapter or car. The Lyriq demo simulates an '
              'active 9 kW charge — try the capacity test.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
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
