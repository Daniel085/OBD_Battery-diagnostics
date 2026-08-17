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

/// Tunable thresholds for health heuristics.
class HealthThresholds {
  /// Cell imbalance (max-min) at rest above which we warn / flag critical (volts).
  final double cellImbalanceWarn;
  final double cellImbalanceCritical;

  /// Module temperature spread above which we warn (celsius).
  final double tempSpreadWarn;

  /// SOH below which we warn / flag critical (percent).
  final double sohWarn;
  final double sohCritical;

  const HealthThresholds({
    this.cellImbalanceWarn = 0.020,
    this.cellImbalanceCritical = 0.050,
    this.tempSpreadWarn = 10.0,
    this.sohWarn = 80.0,
    this.sohCritical = 70.0,
  });
}

class HealthReport {
  final String vehicle;
  final DateTime generatedAt;
  final String? vin;
  final Map<String, Reading> readings;
  final Map<String, double?> metrics;
  final List<HealthWarning> warnings;

  HealthReport({
    required this.vehicle,
    required this.generatedAt,
    this.vin,
    required this.readings,
    required this.metrics,
    required this.warnings,
  });

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
  final HealthThresholds thresholds;
  const BatteryHealthAnalyzer({this.thresholds = const HealthThresholds()});

  /// Build a report from a snapshot of readings keyed by signal id.
  ///
  /// Recognised signal ids (vehicle-agnostic where possible):
  ///   HVBAT_SOH, HVBAT_SOC, HVBAT_VOLTAGE, HVBAT_CURRENT,
  ///   HVBAT_CELL_V_MIN/MAX/AVG, HVBAT_CELLTEMP_MIN/MAX.
  HealthReport analyze({
    required String vehicle,
    required Map<String, Reading> readings,
    String? vin,
    DateTime? now,
    /// Externally measured metrics (e.g. the charge-session capacity test's
    /// measured_soh_percent) merged into the report's metrics map.
    Map<String, double?> extraMetrics = const {},
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

    // Cell imbalance grading (most meaningful at rest / low current).
    if (imbalance != null) {
      final mv = (imbalance * 1000).toStringAsFixed(1);
      if (imbalance >= thresholds.cellImbalanceCritical) {
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
          'Module temperature spread ${tempSpread.toStringAsFixed(1)} °C is high.'));
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
    );
  }
}

String _csv(String s) =>
    s.contains(',') || s.contains('"') ? '"${s.replaceAll('"', '""')}"' : s;
