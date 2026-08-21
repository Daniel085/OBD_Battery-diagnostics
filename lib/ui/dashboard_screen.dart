import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/app_controller.dart';
import '../engine/diagnostics_client.dart';
import 'capacity_screen.dart';
import 'report_screen.dart';
import 'scanner_screen.dart';
import 'terminal_screen.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<AppController>();
    final byGroup = <String, List<Reading>>{};
    for (final r in c.latest.values) {
      byGroup.putIfAbsent(r.signal.group ?? 'other', () => []).add(r);
    }
    const groupOrder = ['summary', 'cells', 'temperature', 'other'];
    final groups = byGroup.keys.toList()
      ..sort((a, b) {
        final ia = groupOrder.indexOf(a);
        final ib = groupOrder.indexOf(b);
        return (ia == -1 ? 99 : ia).compareTo(ib == -1 ? 99 : ib);
      });

    return Scaffold(
      appBar: AppBar(
        title: Text(c.selectedVehicle?.displayName ?? 'Dashboard'),
        actions: [
          IconButton(
            tooltip: 'Capacity test',
            icon: const Icon(Icons.battery_charging_full),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const CapacityScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Health report',
            icon: const Icon(Icons.assignment),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ReportScreen()),
            ),
          ),
          // Advanced/RE tools live behind the overflow so the everyday
          // surface stays approachable; power users know where to look.
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (v) async {
              switch (v) {
                case 'terminal':
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const TerminalScreen()));
                case 'scanner':
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const ScannerScreen()));
                case 'disconnect':
                  await c.disconnect();
                  if (context.mounted) Navigator.of(context).pop();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'terminal',
                child: ListTile(
                  leading: Icon(Icons.terminal),
                  title: Text('Adapter terminal'),
                  subtitle: Text('Advanced'),
                ),
              ),
              PopupMenuItem(
                value: 'scanner',
                child: ListTile(
                  leading: Icon(Icons.travel_explore),
                  title: Text('DID scanner'),
                  subtitle: Text('Advanced'),
                ),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'disconnect',
                child: ListTile(
                  leading: Icon(Icons.link_off),
                  title: Text('Disconnect'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: c.latest.isEmpty
          ? _WaitingState(failures: c.lastFailures)
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                for (final g in groups) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
                    child: Text(g.toUpperCase(),
                        style: Theme.of(context).textTheme.labelLarge),
                  ),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: byGroup[g]!
                        .map((r) => _ReadingCard(reading: r))
                        .toList(),
                  ),
                ],
                if (c.lastFailures.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      '${c.lastFailures.length} signal(s) unavailable this cycle',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
    );
  }
}

class _ReadingCard extends StatelessWidget {
  final Reading reading;
  const _ReadingCard({required this.reading});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 165,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(reading.signal.name,
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(reading.value.toStringAsFixed(2),
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(width: 4),
                  Text(reading.unit,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WaitingState extends StatelessWidget {
  final List<CommandFailure> failures;
  const _WaitingState({required this.failures});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          const Text('Waiting for first readings…'),
          if (failures.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'No signals responded yet. If this is a Lyriq on a generic '
                'clone, the 29-bit battery bus may be unreachable — an OBDLink '
                'CX/MX+ is recommended.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}
