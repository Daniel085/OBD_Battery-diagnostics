import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/app_controller.dart';
import '../engine/capacity_test.dart';
import '../engine/diagnostics_client.dart';
import '../engine/soh_history.dart';
import 'battery_visuals.dart';
import 'capacity_screen.dart';
import 'drive_screen.dart';
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
            tooltip: 'Drive mode (live power)',
            icon: const Icon(Icons.speed),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DriveScreen()),
            ),
          ),
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
                  Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const ScannerScreen()));
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

    // Signals drawn by the cards below are excluded from the plain sections.
    final consumed = <String>{};
    final cards = <Widget>[];

    // ---- Pack: charge ring + current / power / voltage --------------------
    final soc = r('HVBAT_SOC') ?? r('HVBAT_SOC_STD');
    final current = r('HVBAT_CURRENT');
    final volts = r('HVBAT_VOLTAGE') ?? r('HVBAT_NOMINAL_VOLTAGE');
    if (soc != null || current != null) {
      consumed.addAll([
        'HVBAT_SOC',
        'HVBAT_SOC_STD',
        'HVBAT_CURRENT',
        'HVBAT_VOLTAGE',
        'HVBAT_NOMINAL_VOLTAGE',
        'HVBAT_SOC_WINDOW_MIN',
        'HVBAT_SOC_WINDOW_MAX',
      ]);
      cards.add(_PackCard(
        soc: soc?.value,
        windowMin: r('HVBAT_SOC_WINDOW_MIN')?.value,
        windowMax: r('HVBAT_SOC_WINDOW_MAX')?.value,
        cellSoc: r('HVBAT_CELL_SOC_AVG')?.value,
        current: current?.value,
        volts: volts?.value,
        voltsNominal: r('HVBAT_VOLTAGE') == null && volts != null,
      ));
    }

    // ---- Health: SoH figures + their history ------------------------------
    consumed.addAll(['HVBAT_SOH', 'HVBAT_BMS_HEALTH_INDEX']);
    cards.add(_HealthCard(
      capacity: capacity,
      reported: r('HVBAT_SOH'),
      bmsIndex: r('HVBAT_BMS_HEALTH_INDEX'),
      history: controller.sohHistory,
      vehicle: controller.selectedVehicle?.id,
    ));

    // ---- Balance: every min/avg/max triple, plus a battery-temp fallback --
    final rows = <Widget>[];
    for (final t in _triples(latest, consumed)) {
      consumed.addAll(t.ids);
      rows.add(SpreadRow(
        label: t.label,
        unitLabel: _unitLabel(t.unit),
        min: t.min,
        max: t.max,
        avg: t.avg,
        scale: SpreadScale.forUnit(t.unit, t.min, t.max),
      ));
    }
    final hvTemps = latest.values
        .where((x) =>
            x.signal.group == 'temperature' &&
            x.signal.id.startsWith('HVBAT_') &&
            !consumed.contains(x.signal.id))
        .toList();
    if (hvTemps.isNotEmpty &&
        !rows.any((w) => (w as SpreadRow).unitLabel == '°C')) {
      final vs = hvTemps.map((x) => x.value).toList();
      final lo = vs.reduce((a, b) => a < b ? a : b);
      final hi = vs.reduce((a, b) => a > b ? a : b);
      consumed.addAll(hvTemps.map((x) => x.signal.id));
      rows.add(SpreadRow(
        label: 'Battery temps',
        unitLabel: '°C',
        min: lo,
        max: hi,
        avg: vs.reduce((a, b) => a + b) / vs.length,
        // Mixed sensors (cells, coolant, pack points): show the spread but
        // don't grade it as cell balance.
        scale: SpreadScale.forUnit('celsius', lo, hi).unjudged,
        note: '${hvTemps.length} sensors',
      ));
    }
    for (final fam in _numberedFamilies(latest, consumed, group: 'cells')) {
      consumed.addAll(fam.ids);
      rows.add(SpreadRow(
        label: fam.label,
        unitLabel: _unitLabel(fam.unit),
        min: fam.min,
        max: fam.max,
        avg: fam.avg,
        scale: SpreadScale.forUnit(fam.unit, fam.min, fam.max),
        note: '${fam.ids.length} readings',
      ));
    }
    if (rows.isNotEmpty) {
      cards.add(_SectionCard(
        title: 'Cell balance',
        subtitle: 'Where the cells sit, and how far apart',
        child: Column(children: rows),
      ));
    }

    // ---- Everything else, by group, as before ------------------------------
    final byGroup = <String, List<Reading>>{};
    for (final x in latest.values) {
      if (consumed.contains(x.signal.id)) continue;
      byGroup.putIfAbsent(x.signal.group ?? 'other', () => []).add(x);
    }
    const cardGroups = ['cells', 'charging'];
    const compactOrder = ['temperature', 'summary', 'vehicle', 'dynamics'];
    final compactGroups = [
      ...compactOrder.where(byGroup.containsKey),
      ...byGroup.keys
          .where((g) => !compactOrder.contains(g) && !cardGroups.contains(g)),
    ];

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final c in cards) ...[c, const SizedBox(height: 10)],
        for (final g in cardGroups.where(byGroup.containsKey)) ...[
          _sectionTitle(context, g),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: byGroup[g]!.map((x) => _ReadingCard(reading: x)).toList(),
          ),
        ],
        for (final g in compactGroups) ...[
          _sectionTitle(context, g),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children:
                    byGroup[g]!.map((x) => _CompactRow(reading: x)).toList(),
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

  static String _unitLabel(String unit) => switch (unit) {
        'volts' => 'V',
        'percent' => '%',
        'celsius' => '°C',
        'amps' => 'A',
        _ => unit,
      };
}

/// A `<base>_MIN` / `<base>_MAX` (/ optional `<base>_AVG`) family of signals.
class _Triple {
  final String label, unit;
  final double min, max;
  final double? avg;
  final List<String> ids;
  _Triple(this.label, this.unit, this.min, this.max, this.avg, this.ids);
}

/// Find min/max(/avg) families by id convention, so any signal set that
/// follows it gets a spread row with no per-vehicle UI code.
List<_Triple> _triples(Map<String, Reading> latest, Set<String> skip) {
  final out = <_Triple>[];
  for (final id in latest.keys.where((k) => k.endsWith('_MIN')).toList()
    ..sort()) {
    final base = id.substring(0, id.length - 4);
    final mn = latest[id], mx = latest['${base}_MAX'];
    if (mn == null || mx == null || skip.contains(id)) continue;
    final av = latest['${base}_AVG'];
    final label = mn.signal.name
        .replaceAll(
            RegExp(r'\s*\((min|minimum)\)\s*$', caseSensitive: false), '')
        .replaceFirst(RegExp(r'^HV battery\s+', caseSensitive: false), '');
    out.add(_Triple(
      label.isEmpty ? base : '${label[0].toUpperCase()}${label.substring(1)}',
      mn.unit,
      mn.value,
      mx.value,
      av?.value,
      [id, '${base}_MAX', if (av != null) '${base}_AVG'],
    ));
  }
  return out;
}

/// Numbered families like `HVBAT_MODULE_V_1..N` in one group: one spread row
/// instead of N cards. Needs 2+ members sharing a unit.
List<_Triple> _numberedFamilies(Map<String, Reading> latest, Set<String> skip,
    {required String group}) {
  final fams = <String, List<Reading>>{};
  for (final r in latest.values) {
    if (r.signal.group != group || skip.contains(r.signal.id)) continue;
    final m = RegExp(r'^(.*)_(\d+)$').firstMatch(r.signal.id);
    if (m == null) continue;
    fams.putIfAbsent(m.group(1)!, () => []).add(r);
  }
  final out = <_Triple>[];
  for (final MapEntry(key: base, value: rs) in fams.entries) {
    if (rs.length < 2 || rs.any((r) => r.unit != rs.first.unit)) continue;
    final vs = rs.map((r) => r.value).toList();
    // "HV battery module voltage 2 (unverified)" -> "Module voltage
    // (unverified)": drop the member number, keep any trailing qualifier.
    final label = rs.first.signal.name
        .replaceFirst(RegExp(r'\s*\d+(?=\s*(\([^)]*\))?\s*$)'), '')
        .replaceFirst(RegExp(r'^HV battery\s+', caseSensitive: false), '');
    out.add(_Triple(
      label.isEmpty ? base : '${label[0].toUpperCase()}${label.substring(1)}',
      rs.first.unit,
      vs.reduce((a, b) => a < b ? a : b),
      vs.reduce((a, b) => a > b ? a : b),
      vs.reduce((a, b) => a + b) / vs.length,
      [for (final r in rs) r.signal.id],
    ));
  }
  return out;
}

class _SectionCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  const _SectionCard({required this.title, required this.child, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: text.titleMedium),
            if (subtitle != null) Text(subtitle!, style: text.bodySmall),
            const SizedBox(height: 6),
            child,
          ],
        ),
      ),
    );
  }
}

/// Charge ring on the left; current, power, and pack voltage on the right.
class _PackCard extends StatelessWidget {
  final double? soc, windowMin, windowMax, cellSoc, current, volts;
  final bool voltsNominal;

  const _PackCard({
    this.soc,
    this.windowMin,
    this.windowMax,
    this.cellSoc,
    this.current,
    this.volts,
    this.voltsNominal = false,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final a = current;
    final (state, icon, color) = a == null
        ? ('', Icons.remove, null)
        : a <= -2
            ? ('Charging', Icons.bolt, Colors.green)
            : a >= 2
                ? ('Discharging', Icons.flash_on, Colors.orange)
                : ('Idle', Icons.pause_circle_outline, null);
    final kw = (a == null || volts == null) ? null : a.abs() * volts! / 1000;
    final hasWindow = windowMin != null && windowMax != null;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: a == null
            ? null
            : () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const DriveScreen())),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (soc != null)
                    ChargeRing(
                      socPct: soc!,
                      windowMinPct: windowMin,
                      windowMaxPct: windowMax,
                      cellSocPct: cellSoc,
                    ),
                  if (soc != null) const SizedBox(width: 18),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (a != null) ...[
                          Text('Pack current', style: text.bodySmall),
                          // Wraps the state under the value on narrow
                          // screens instead of overflowing.
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 6,
                            children: [
                              Text('${a.abs().toStringAsFixed(1)} A',
                                  style: text.headlineSmall
                                      ?.copyWith(fontWeight: FontWeight.w600)),
                              Row(mainAxisSize: MainAxisSize.min, children: [
                                Icon(icon, size: 18, color: color),
                                Text(state,
                                    style: text.labelMedium
                                        ?.copyWith(color: color)),
                              ]),
                            ],
                          ),
                          const SizedBox(height: 10),
                        ],
                        if (kw != null)
                          _kv(context, 'Power', '${kw.toStringAsFixed(1)} kW'),
                        if (volts != null)
                          _kv(
                              context,
                              voltsNominal ? 'Nominal voltage' : 'Pack voltage',
                              '${volts!.toStringAsFixed(1)} V'),
                      ],
                    ),
                  ),
                ],
              ),
              if (hasWindow)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    'Outer ring: the car uses ${windowMin!.toStringAsFixed(0)}–'
                    '${windowMax!.toStringAsFixed(0)} % of raw cell capacity'
                    '${cellSoc == null ? '' : '; cells now at ${cellSoc!.toStringAsFixed(0)} %'}.',
                    style: text.bodySmall,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(children: [
        Expanded(
            child: Text(k,
                style: text.bodyMedium, overflow: TextOverflow.ellipsis)),
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(v,
                style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          ),
        ),
      ]),
    );
  }
}

/// The SoH figures side by side (never merged — measured, reported, and a
/// candidate index answer different questions), with their history below.
class _HealthCard extends StatelessWidget {
  final CapacityAnalysis? capacity;
  final Reading? reported;
  final Reading? bmsIndex;
  final SohHistory history;
  final String? vehicle;

  const _HealthCard({
    required this.capacity,
    required this.reported,
    required this.bmsIndex,
    required this.history,
    required this.vehicle,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    void toCapacity(BuildContext c) => Navigator.of(c)
        .push(MaterialPageRoute(builder: (_) => const CapacityScreen()));

    final tiles = <Widget>[];
    if (capacity?.sohPct != null) {
      tiles.add(_HealthTile(
        label: 'Measured SOH',
        value: '${capacity!.sohPct!.toStringAsFixed(1)} %',
        sub: 'capacity test · ${capacity!.packKwh!.toStringAsFixed(0)} kWh',
        onTap: toCapacity,
      ));
    }
    if (reported != null) {
      tiles.add(_HealthTile(
        label: capacity?.sohPct != null ? 'Reported SOH' : 'State of health',
        value: '${reported!.value.toStringAsFixed(0)} %',
        sub: 'reported by vehicle',
      ));
    }
    if (tiles.isEmpty) {
      tiles.add(_HealthTile(
        label: 'State of health',
        value: '—',
        sub: 'run a capacity test',
        onTap: toCapacity,
      ));
    }
    if (bmsIndex != null) {
      // Lyriq 451D: a CANDIDATE SOH. 0 means "not available" (sparse mode or
      // not yet settled after wake), never "0 % healthy".
      final v = bmsIndex!.value;
      tiles.add(v <= 0 || v > 100
          ? const _HealthTile(
              label: 'BMS health index',
              value: '—',
              sub: 'available with vehicle on')
          : _HealthTile(
              label: 'BMS health index',
              value: '${v.toStringAsFixed(0)} %',
              sub: '451D · unverified as SOH'));
    }

    final styles = {
      SohSource.measured: SohSeriesStyle('measured', cs.primary),
      SohSource.reported: SohSeriesStyle('reported', cs.tertiary),
      SohSource.bmsIndex: SohSeriesStyle('BMS index', cs.secondary),
    };
    final series = <SohSource, List<SohEntry>>{
      if (vehicle != null)
        for (final s in SohSource.values)
          if (history.series(vehicle!, s).isNotEmpty)
            s: history.series(vehicle!, s),
    };
    final count = series.values.fold<int>(0, (n, s) => n + s.length);
    final days = series.isEmpty
        ? 0
        : series.values
            .map((s) => s.last.at.difference(s.first.at).inDays)
            .reduce((a, b) => a > b ? a : b);
    final trendSource = series.keys.isEmpty ? null : series.keys.first;
    final trend = (vehicle == null || trendSource == null)
        ? null
        : history.trend(vehicle!, trendSource);

    return _SectionCard(
      title: 'Battery health',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final t in tiles) Expanded(child: t),
            ],
          ),
          const SizedBox(height: 12),
          if (count >= 2) ...[
            Text('History', style: text.labelLarge),
            const SizedBox(height: 6),
            SohHistoryChart(series: series, styles: styles),
            if (trend != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${trend.pctPerYear >= 0 ? '+' : '−'}'
                  '${trend.pctPerYear.abs().toStringAsFixed(1)} % per year '
                  'over ${trend.spanDays} days (${styles[trendSource]!.label})',
                  style: text.bodySmall,
                ),
              ),
          ] else
            Text(
              count == 1
                  ? 'History started — one reading saved. Each day you '
                      'connect adds a point; a trend shows after a month.'
                  : 'Health readings are saved each day you connect, to '
                      'build a history.',
              style: text.bodySmall,
            ),
          if (count >= 2 && days < SohHistory.minTrendDays)
            Text(
                'Trend shows after ${SohHistory.minTrendDays} days of readings.',
                style: text.bodySmall),
        ],
      ),
    );
  }
}

class _HealthTile extends StatelessWidget {
  final String label, value;
  final String? sub;
  final void Function(BuildContext)? onTap;
  const _HealthTile(
      {required this.label, required this.value, this.sub, this.onTap});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap == null ? null : () => onTap!(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: text.bodySmall, overflow: TextOverflow.ellipsis),
            Text(value,
                style:
                    text.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
            if (sub != null)
              Text(sub!,
                  style: text.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
          ],
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
                      child: Text(_valueText(reading, 2),
                          style: Theme.of(context).textTheme.headlineSmall),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(_unitText(reading.unit),
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
            _withUnit(reading),
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

/// Display helpers for plain readings: short unit symbols instead of the
/// signal set's unit names, no decimals on big counters, and miles alongside
/// kilometres.
String _unitText(String unit) => switch (unit) {
      'celsius' => '°C',
      'percent' => '%',
      'volts' => 'V',
      'amps' => 'A',
      _ => unit,
    };

String _valueText(Reading r, int decimals) => r.value.abs() >= 1000
    ? r.value.round().toString()
    : r.value.toStringAsFixed(decimals);

String _withUnit(Reading r) {
  final v = '${_valueText(r, 1)} ${_unitText(r.unit)}'.trim();
  if (r.unit == 'km') return '$v · ${(r.value / 1.609344).round()} mi';
  return v;
}
