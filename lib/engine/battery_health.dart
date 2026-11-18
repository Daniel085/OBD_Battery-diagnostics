/// Battery health model + report generation.
///
/// Turns a snapshot of decoded [Reading]s into a structured [HealthReport] with
/// derived metrics (SOH, cell imbalance, temperature spread) and severity-graded
/// warnings. The report serialises to JSON and CSV here; PDF rendering lives in
/// the UI layer (it needs Flutter's `pdf` package) but consumes this same model.
///
/// Thresholds are conservative, documented defaults; they can be overridden per
/// vehicle. They are heuristics for surfacing concerns, not manufacturer specs.
library;

import 'dart:convert';

import 'diagnostics_client.dart';
import 'display_units.dart';

enum Severity { ok, info, warning, critical }

class HealthWarning {
  final Severity severity;
  final String code;
  final String message;
  const HealthWarning(this.severity, this.code, this.message);

  Map<String, dynamic> toJson() => {
        'severity': severity.name,
        'code': code,
        'message': message,
      };
}

/// A cycle count worked out from lifetime charge throughput.
class EquivalentCycles {
  final double cycles;

  /// The lifetime counter it was computed from.
  final Reading basis;

  /// The capacity it was divided by, and whether that came from the vehicle
  /// (true) or from the signal set's rated figure (false).
  final double capacityAh;
  final bool capacityReported;

  /// False while the counter's (or the reported capacity's) decoding is
  /// unverified.
  final bool confirmed;
  const EquivalentCycles({
    required this.cycles,
    required this.basis,
    required this.capacityAh,
    required this.capacityReported,
    required this.confirmed,
  });
}

/// Tunable thresholds for health heuristics.
class HealthThresholds {
  /// Cell imbalance (max-min) at rest above which we warn / flag critical (volts).
  final double cellImbalanceWarn;
  final double cellImbalanceCritical;

  /// Pack current (A, either direction) below which the pack counts as at
  /// rest. Cell voltages spread apart under load (weaker and colder cells sag
  /// more), so the imbalance limits above only mean something near rest.
  final double restCurrentAmps;

  /// Module temperature spread above which we warn (celsius).
  final double tempSpreadWarn;

  /// SOH below which we warn / flag critical (percent).
  final double sohWarn;
  final double sohCritical;

  const HealthThresholds({
    this.cellImbalanceWarn = 0.020,
    this.cellImbalanceCritical = 0.050,
    this.restCurrentAmps = 2.0,
    this.tempSpreadWarn = 10.0,
    this.sohWarn = 80.0,
    this.sohCritical = 70.0,
  });

  /// True when [amps] (pack current, either sign) is known and above the rest
  /// band. Unknown current is not "under load".
  bool isUnderLoad(double? amps) =>
      amps != null && amps.abs() >= restCurrentAmps;
}

class HealthReport {
  final String vehicle;
  final DateTime generatedAt;
  final String? vin;
  final Map<String, Reading> readings;
  final Map<String, double?> metrics;
  final List<HealthWarning> warnings;

  /// Keys of [metrics] that come from a signal whose decoding has not been
  /// confirmed on the vehicle (unit marked `?`). Shown, never graded.
  final Set<String> unconfirmedMetrics;

  HealthReport({
    required this.vehicle,
    required this.generatedAt,
    this.vin,
    required this.readings,
    required this.metrics,
    required this.warnings,
    this.unconfirmedMetrics = const {},
  });

  /// A metric's key as shown to a person: marked when it is unconfirmed.
  String metricLabel(String key) =>
      unconfirmedMetrics.contains(key) ? '$key (unconfirmed)' : key;

  /// A metric's value as text. Metrics measured in hours also get the
  /// duration in days or years: `8.9 years (78200 h)`.
  String metricText(String key) {
    final v = metrics[key];
    if (v == null) return '—';
    if (key.endsWith('_hours') && v.abs() >= 24) {
      final d = DisplayUnits.readableHours(v);
      return '${d.value.toStringAsFixed(1)} ${d.unit} (${v.round()} h)';
    }
    if (key.endsWith('_cycles')) return v.round().toString();
    return v.toStringAsFixed(3);
  }

  Severity get overallSeverity {
    var worst = Severity.ok;
    for (final w in warnings) {
      if (w.severity.index > worst.index) worst = w.severity;
    }
    return worst;
  }

  Map<String, dynamic> toJson() => {
        'vehicle': vehicle,
        'generatedAt': generatedAt.toUtc().toIso8601String(),
        if (vin != null) 'vin': vin,
        'overallSeverity': overallSeverity.name,
        'readings': {
          for (final e in readings.entries)
            e.key: {
              'name': e.value.signal.name,
              'value': e.value.value,
              'unit': e.value.unit,
              'group': e.value.signal.group,
            }
        },
        'metrics': metrics,
        if (unconfirmedMetrics.isNotEmpty)
          'unconfirmedMetrics': unconfirmedMetrics.toList(),
        'warnings': warnings.map((w) => w.toJson()).toList(),
      };

  String toJsonString({bool pretty = true}) => pretty
      ? const JsonEncoder.withIndent('  ').convert(toJson())
      : jsonEncode(toJson());

  /// Flat CSV of every reading: id,name,value,unit,group.
  String toReadingsCsv() {
    final rows = <String>['signal_id,name,value,unit,group'];
    for (final e in readings.entries) {
      final r = e.value;
      rows.add([
        e.key,
        _csv(r.signal.name),
        r.value.toString(),
        r.unit,
        r.signal.group ?? '',
      ].join(','));
    }
    return rows.join('\n');
  }
}

class BatteryHealthAnalyzer {
  /// Ageing, lifetime and 12 V battery signals copied into the report's
  /// metrics when a vehicle provides them (signal id -> metric key). Reported, not graded:
  /// there are no agreed limits for them yet.
  static const reportedSignals = {
    'HVBAT_SOH_RESISTANCE': 'resistance_soh_percent',
    'HVBAT_ISOLATION': 'isolation_resistance_kohm',
    'HVBAT_HV_ON_HOURS': 'hv_on_hours',
    'HVBAT_AGE_HOURS': 'battery_age_hours',
    'HVBAT_CONTACTOR_CYCLES': 'contactor_cycles',
    'HVBAT_CONTACTOR_CYCLES_LOAD': 'contactor_cycles_under_load',
    'HVBAT_AH_CHARGED': 'lifetime_charge_in_ah',
    'HVBAT_AH_DISCHARGED': 'lifetime_charge_out_ah',
    'LVBAT_SOC_PARK': 'aux_12v_soc_at_park_percent',
    'LVBAT_TOPUP_SOC_START': 'aux_12v_soc_before_topup_percent',
    'LVBAT_TOPUP_SOC_END': 'aux_12v_soc_after_topup_percent',
    'LVBAT_TOPUP_KM': 'aux_12v_last_topup_km',
    'LVBAT_SOC': 'aux_12v_soc_percent',
    'LVBAT_VOLTAGE': 'aux_12v_voltage',
    'LVBAT_AGE_HOURS': 'aux_12v_age_hours',
    'HVBAT_CAPACITY_AH': 'reported_capacity_ah',
  };

  /// Equivalent full cycles = lifetime charge throughput / capacity, or
  /// null when the vehicle gives no lifetime counter or no capacity.
  /// Capacity is the signal set's rated figure ([ratedAh]) or, failing
  /// that, the capacity the vehicle itself reports (`HVBAT_CAPACITY_AH`).
  static EquivalentCycles? equivalentFullCycles(
      Map<String, Reading> readings, double? ratedAh) {
    final reported = readings['HVBAT_CAPACITY_AH'];
    final fromSet = ratedAh != null && ratedAh > 0;
    final capacity = fromSet ? ratedAh : reported?.value;
    if (capacity == null || capacity <= 0) return null;
    final out = readings['HVBAT_AH_DISCHARGED'];
    final into = readings['HVBAT_AH_CHARGED'];
    bool sure(Reading? r) => r != null && !r.unit.endsWith('?');
    final basis = sure(out) ? out : (sure(into) ? into : (out ?? into));
    if (basis == null) return null;
    return EquivalentCycles(
      cycles: basis.value / capacity,
      basis: basis,
      capacityAh: capacity,
      capacityReported: !fromSet,
      confirmed: sure(basis) && (fromSet || sure(reported)),
    );
  }

  /// Signal ids carrying one battery module's defect code (0 = none).
  static final moduleDefectId = RegExp(r'^HVBAT_MODULE_(\d+)_DEFECT$');

  final HealthThresholds thresholds;
  const BatteryHealthAnalyzer({this.thresholds = const HealthThresholds()});

  /// Build a report from a snapshot of readings keyed by signal id.
  ///
  /// Recognised signal ids (vehicle-agnostic where possible):
  ///   HVBAT_SOH, HVBAT_SOC, HVBAT_VOLTAGE, HVBAT_CURRENT,
  ///   HVBAT_CELL_V_MIN/MAX/AVG, HVBAT_CELLTEMP_MIN/MAX,
  ///   HVBAT_MODULE_<n>_DEFECT, and the report-only ids in [reportedSignals].
  HealthReport analyze({
    required String vehicle,
    required Map<String, Reading> readings,
    String? vin,
    DateTime? now,
    /// Externally measured metrics (e.g. the charge-session capacity test's
    /// measured_soh_percent) merged into the report's metrics map.
    Map<String, double?> extraMetrics = const {},
    /// Units for the human-readable warning text only; metrics and
    /// thresholds stay in the signal set's units.
    DisplayUnits units = const DisplayUnits(),
    /// The pack's rated capacity (signal set `pack.ratedAh`), for the
    /// equivalent-full-cycle count.
    double? ratedAh,
  }) {
    final metrics = <String, double?>{...extraMetrics};
    final warnings = <HealthWarning>[];

    double? val(String id) => readings[id]?.value;

    final soh = val('HVBAT_SOH');
    metrics['soh_percent'] = soh;

    final cellMin = val('HVBAT_CELL_V_MIN');
    final cellMax = val('HVBAT_CELL_V_MAX');
    double? imbalance;
    if (cellMin != null && cellMax != null) {
      imbalance = cellMax - cellMin;
      metrics['cell_imbalance_volts'] = imbalance;
    }

    final tMin = val('HVBAT_CELLTEMP_MIN');
    final tMax = val('HVBAT_CELLTEMP_MAX');
    double? tempSpread;
    if (tMin != null && tMax != null) {
      tempSpread = tMax - tMin;
      metrics['temp_spread_celsius'] = tempSpread;
    }

    final unconfirmed = <String>{};
    for (final e in reportedSignals.entries) {
      final r = readings[e.key];
      if (r == null) continue;
      metrics[e.value] = r.value;
      if (r.unit.endsWith('?')) unconfirmed.add(e.value);
    }

    // Equivalent full cycles: lifetime charge throughput over the rated
    // capacity. Discharge is the conventional side; the charge side is used
    // when it is the one whose decoding is confirmed. Throughput includes
    // regen, so this is wear, not a count of plug-in charges.
    final cycles = equivalentFullCycles(readings, ratedAh);
    if (cycles != null) {
      const key = 'equivalent_full_cycles';
      metrics[key] = cycles.cycles;
      if (!cycles.confirmed) unconfirmed.add(key);
    }

    // Per-module defect codes (0 = none). A non-zero code is reported; it
    // only counts as a warning once the vehicle's decoding is confirmed.
    final moduleCodes = <int, Reading>{
      for (final r in readings.values)
        if (moduleDefectId.firstMatch(r.signal.id) case final m?)
          int.parse(m.group(1)!): r,
    };
    if (moduleCodes.isNotEmpty) {
      const key = 'modules_reporting_defect';
      final bad = moduleCodes.keys.where((n) => moduleCodes[n]!.value != 0)
          .toList()
        ..sort();
      metrics[key] = bad.length.toDouble();
      final unsure = moduleCodes.values.any((r) => r.unit.endsWith('?'));
      if (unsure) unconfirmed.add(key);
      for (final n in bad) {
        final code = moduleCodes[n]!.value.round();
        warnings.add(HealthWarning(
            unsure ? Severity.info : Severity.warning,
            'MODULE_DEFECT',
            'Battery module $n reports defect code $code.'
                '${unsure ? ' This reading is not confirmed on this vehicle; check it with a second tool.' : ''}'));
      }
    }

    // SOH grading.
    if (soh != null) {
      if (soh < thresholds.sohCritical) {
        warnings.add(HealthWarning(Severity.critical, 'SOH_CRITICAL',
            'State of health ${soh.toStringAsFixed(1)}% is below ${thresholds.sohCritical}%.'));
      } else if (soh < thresholds.sohWarn) {
        warnings.add(HealthWarning(Severity.warning, 'SOH_LOW',
            'State of health ${soh.toStringAsFixed(1)}% is below ${thresholds.sohWarn}%.'));
      }
    }

    // Cell imbalance grading: only near rest. Under load the spread is not
    // comparable to the limits, so it is reported but never graded. With no
    // current signal the load is unknown and the spread is graded as read.
    final amps = val('HVBAT_CURRENT');
    final underLoad = thresholds.isUnderLoad(amps);
    if (amps != null) metrics['pack_current_amps'] = amps;
    if (imbalance != null) {
      final mv = (imbalance * 1000).toStringAsFixed(1);
      if (underLoad) {
        if (imbalance >= thresholds.cellImbalanceWarn) {
          warnings.add(HealthWarning(
              Severity.info,
              'CELL_IMBALANCE_UNDER_LOAD',
              'Cell voltage spread $mv mV was read under load '
                  '(${amps!.abs().toStringAsFixed(1)} A), where cells always '
                  'spread apart. It is only graded near rest (under '
                  '${thresholds.restCurrentAmps.toStringAsFixed(0)} A): '
                  'check again with the car idle.'));
        }
      } else if (imbalance >= thresholds.cellImbalanceCritical) {
        warnings.add(HealthWarning(Severity.critical, 'CELL_IMBALANCE_HIGH',
            'Cell voltage spread $mv mV suggests a weak or failing cell/module.'));
      } else if (imbalance >= thresholds.cellImbalanceWarn) {
        warnings.add(HealthWarning(Severity.warning, 'CELL_IMBALANCE',
            'Cell voltage spread $mv mV is above the healthy ~20 mV range.'));
      }
    }

    // Temperature spread grading.
    if (tempSpread != null && tempSpread >= thresholds.tempSpreadWarn) {
      warnings.add(HealthWarning(Severity.warning, 'TEMP_SPREAD',
          'Module temperature spread '
          '${units.convertDelta('celsius', tempSpread).toStringAsFixed(1)} '
          '${units.symbolFor('celsius')} is high.'));
    }

    if (warnings.isEmpty && readings.isNotEmpty) {
      warnings.add(const HealthWarning(
          Severity.ok, 'OK', 'No battery health concerns detected.'));
    }

    return HealthReport(
      vehicle: vehicle,
      generatedAt: now ?? DateTime.now(),
      vin: vin,
      readings: readings,
      metrics: metrics,
      warnings: warnings,
      unconfirmedMetrics: unconfirmed,
    );
  }
}

String _csv(String s) =>
    s.contains(',') || s.contains('"') ? '"${s.replaceAll('"', '""')}"' : s;
