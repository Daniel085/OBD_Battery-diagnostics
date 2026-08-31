import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/app_controller.dart';
import '../engine/capacity_test.dart';
import '../engine/diagnostics_client.dart';
import 'capacity_screen.dart';
import 'report_screen.dart';
import 'scanner_screen.dart';
import 'terminal_screen.dart';

/// Live dashboard with an explicit hierarchy: what a battery-focused user
/// cares about (pack current + state, SOH, temperatures) renders as hero
/// cards; supporting voltages as medium cards; context signals (dynamics,
/// odometer, 12V rails) as compact rows. The flat everything-is-equal grid
/// buried the headline data.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<AppController>();
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
          : _DashboardBody(controller: c),
    );
  }
}

class _DashboardBody extends StatelessWidget {
  final AppController controller;
  const _DashboardBody({required this.controller});

  @override
  Widget build(BuildContext context) {
    final latest = controller.latest;
    Reading? r(String id) => latest[id];

    final capacity = controller.capacityTest?.analyze();

    // Signals promoted into hero cards are excluded from the sections below.
    final consumed = <String>{};
    final heroes = <Widget>[];

    final current = r('HVBAT_CURRENT');
    final nominalV = r('HVBAT_NOMINAL_VOLTAGE') ?? r('HVBAT_VOLTAGE');
    if (current != null) {
      consumed.addAll(['HVBAT_CURRENT', 'HVBAT_NOMINAL_VOLTAGE']);
      heroes.add(_currentHero(context, current, nominalV));
    }

    heroes.add(_sohHero(context, capacity, r('HVBAT_SOH')));
    consumed.add('HVBAT_SOH');

    final soc = r('HVBAT_SOC') ?? r('HVBAT_SOC_STD');
    if (soc != null) {
      consumed.addAll(['HVBAT_SOC', 'HVBAT_SOC_STD']);
      heroes.add(_HeroCard(
        label: 'State of charge',
        value: '${soc.value.toStringAsFixed(0)} %',
        sub: 'reported by vehicle',
        icon: Icons.battery_5_bar,
      ));
    }

    final temps = latest.values
        .where((x) => x.signal.group == 'temperature')
        .toList();
    if (temps.isNotEmpty) {
      final lo = temps.map((x) => x.value).reduce((a, b) => a < b ? a : b);
      final hi = temps.map((x) => x.value).reduce((a, b) => a > b ? a : b);
      heroes.add(_HeroCard(
        label: 'Battery temps',
        value: lo == hi
            ? '${lo.toStringAsFixed(0)} °C'
            : '${lo.toStringAsFixed(0)}–${hi.toStringAsFixed(0)} °C',
        sub: '${temps.length} sensors',
        icon: Icons.thermostat,
      ));
    }

    // Remaining signals by group, in a fixed meaningful order.
    final byGroup = <String, List<Reading>>{};
    for (final x in latest.values) {
      if (consumed.contains(x.signal.id)) continue;
      byGroup.putIfAbsent(x.signal.group ?? 'other', () => []).add(x);
    }
    const cardGroups = ['cells', 'charging'];
    const compactOrder = ['temperature', 'summary', 'vehicle', 'dynamics'];
    final compactGroups = [
      ...compactOrder.where(byGroup.containsKey),
      ...byGroup.keys.where(
          (g) => !compactOrder.contains(g) && !cardGroups.contains(g)),
    ];

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.6,
          children: heroes,
        ),
        for (final g in cardGroups.where(byGroup.containsKey)) ...[
          _sectionTitle(context, g),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children:
                byGroup[g]!.map((x) => _ReadingCard(reading: x)).toList(),
          ),
        ],
        for (final g in compactGroups) ...[
          _sectionTitle(context, g),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: byGroup[g]!
                    .map((x) => _CompactRow(reading: x))
                    .toList(),
              ),
            ),
          ),
        ],
        if (controller.lastFailures.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              '${controller.lastFailures.length} signal(s) unavailable this cycle',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  Widget _sectionTitle(BuildContext context, String g) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
        child: Text(g.toUpperCase(),
            style: Theme.of(context).textTheme.labelLarge),
      );

  Widget _currentHero(
      BuildContext context, Reading current, Reading? nominalV) {
    final a = current.value;
    final (state, icon, color) = a <= -2
        ? ('Charging', Icons.bolt, Colors.green)
        : a >= 2
            ? ('Discharging', Icons.flash_on, Colors.orange)
            : ('Idle', Icons.pause_circle_outline, null);
    final kw = nominalV == null ? null : a.abs() * nominalV.value / 1000;
    return _HeroCard(
      label: 'Pack current',
      value: '${a.abs().toStringAsFixed(1)} A',
      sub: kw == null ? state : '$state · ${kw.toStringAsFixed(1)} kW',
      icon: icon,
      accent: color,
    );
  }

  Widget _sohHero(
      BuildContext context, CapacityAnalysis? capacity, Reading? reported) {
    if (capacity?.sohPct != null) {
      return _HeroCard(
        label: 'State of health',
        value: '${capacity!.sohPct!.toStringAsFixed(1)} %',
        sub: 'measured · ${capacity.packKwh!.toStringAsFixed(0)} kWh',
        icon: Icons.favorite,
        onTap: (context) => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const CapacityScreen())),
      );
    }
    if (reported != null) {
      return _HeroCard(
        label: 'State of health',
        value: '${reported.value.toStringAsFixed(0)} %',
        sub: 'reported by vehicle',
        icon: Icons.favorite_border,
      );
    }
    return _HeroCard(
      label: 'State of health',
      value: '—',
      sub: 'run a capacity test',
      icon: Icons.science_outlined,
      onTap: (context) => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const CapacityScreen())),
    );
  }
}

class _HeroCard extends StatelessWidget {
  final String label;
  final String value;
  final String? sub;
  final IconData icon;
  final Color? accent;
  final void Function(BuildContext)? onTap;

  const _HeroCard({
    required this.label,
    required this.value,
    required this.icon,
    this.sub,
    this.accent,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap == null ? null : () => onTap!(context),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(icon, size: 18, color: accent),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(label,
                        style: Theme.of(context).textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
              Text(value,
                  style: Theme.of(context)
                      .textTheme
                      .headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
              if (sub != null)
                Text(sub!,
                    style: Theme.of(context).textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
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
                  // Flexible + scale-down so long values shrink instead of
                  // overflowing the fixed-width card.
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(reading.value.toStringAsFixed(2),
                          style: Theme.of(context).textTheme.headlineSmall),
                    ),
                  ),
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

class _CompactRow extends StatelessWidget {
  final Reading reading;
  const _CompactRow({required this.reading});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(reading.signal.name,
                style: Theme.of(context).textTheme.bodyMedium,
                overflow: TextOverflow.ellipsis),
          ),
          Text(
            '${reading.value.toStringAsFixed(1)} ${reading.unit}',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
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
