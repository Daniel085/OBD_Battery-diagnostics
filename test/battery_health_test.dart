import 'dart:convert';

import 'package:obd_battery_diagnostics/engine/battery_health.dart';
import 'package:obd_battery_diagnostics/engine/diagnostics_client.dart';
import 'package:obd_battery_diagnostics/engine/logging.dart';
import 'package:obd_battery_diagnostics/engine/signal_set.dart';
import 'package:test/test.dart';

Reading _r(String id, String name, double v, String unit, [String? group]) =>
    Reading(
      Signal(id: id, name: name, group: group, fmt: SignalFormat(len: 16, unit: unit)),
      v,
      DateTime.utc(2026, 1, 1),
    );

void main() {
  const analyzer = BatteryHealthAnalyzer();
  final at = DateTime.utc(2026, 1, 1);

  group('BatteryHealthAnalyzer', () {
    test('healthy pack yields OK', () {
      final readings = {
        'HVBAT_SOH': _r('HVBAT_SOH', 'SOH', 94, 'percent', 'summary'),
        'HVBAT_CELL_V_MIN': _r('HVBAT_CELL_V_MIN', 'min', 3.900, 'volts', 'cells'),
        'HVBAT_CELL_V_MAX': _r('HVBAT_CELL_V_MAX', 'max', 3.908, 'volts', 'cells'),
        'HVBAT_CELLTEMP_MIN': _r('HVBAT_CELLTEMP_MIN', 'tmin', 22, 'celsius', 'temperature'),
        'HVBAT_CELLTEMP_MAX': _r('HVBAT_CELLTEMP_MAX', 'tmax', 25, 'celsius', 'temperature'),
      };
      final report = analyzer.analyze(vehicle: 'BMW-330e-2018', readings: readings, now: at);
      expect(report.overallSeverity, Severity.ok);
      expect(report.metrics['cell_imbalance_volts'], closeTo(0.008, 1e-9));
      expect(report.metrics['temp_spread_celsius'], closeTo(3.0, 1e-9));
    });

    test('low SOH warns, very low SOH is critical', () {
      final warn = analyzer.analyze(
        vehicle: 'v',
        readings: {'HVBAT_SOH': _r('HVBAT_SOH', 'SOH', 78, 'percent')},
        now: at,
      );
      expect(warn.overallSeverity, Severity.warning);

      final crit = analyzer.analyze(
        vehicle: 'v',
        readings: {'HVBAT_SOH': _r('HVBAT_SOH', 'SOH', 65, 'percent')},
        now: at,
      );
      expect(crit.overallSeverity, Severity.critical);
      expect(crit.warnings.any((w) => w.code == 'SOH_CRITICAL'), isTrue);
    });

    test('large cell imbalance is critical', () {
      final report = analyzer.analyze(
        vehicle: 'v',
        readings: {
          'HVBAT_CELL_V_MIN': _r('HVBAT_CELL_V_MIN', 'min', 3.60, 'volts'),
          'HVBAT_CELL_V_MAX': _r('HVBAT_CELL_V_MAX', 'max', 3.66, 'volts'),
        },
        now: at,
      );
      expect(report.overallSeverity, Severity.critical);
      expect(report.metrics['cell_imbalance_volts'], closeTo(0.06, 1e-9));
    });

    test('serialises to JSON and CSV', () {
      final report = analyzer.analyze(
        vehicle: 'BMW-330e-2018',
        vin: 'WBA00000000000000',
        readings: {'HVBAT_SOC': _r('HVBAT_SOC', 'SOC', 61.5, 'percent', 'summary')},
        now: at,
      );
      final json = jsonDecode(report.toJsonString()) as Map<String, dynamic>;
      expect(json['vehicle'], 'BMW-330e-2018');
      expect(json['vin'], 'WBA00000000000000');
      expect((json['readings'] as Map)['HVBAT_SOC'], isNotNull);

      final csv = report.toReadingsCsv();
      expect(csv.split('\n').first, 'signal_id,name,value,unit,group');
      expect(csv, contains('HVBAT_SOC'));
    });
  });

  group('InMemorySampleSink', () {
    test('logs samples and emits wide CSV', () async {
      final sink = InMemorySampleSink();
      await sink.add(LogSample(at, {'HVBAT_SOC': 80.0, 'HVBAT_VOLTAGE': 350.1}));
      await sink.add(LogSample(at.add(const Duration(seconds: 1)), {'HVBAT_SOC': 79.5}));
      final csv = sink.toCsv();
      final lines = csv.split('\n');
      expect(lines.first, 'timestamp,HVBAT_SOC,HVBAT_VOLTAGE');
      // second sample is missing HVBAT_VOLTAGE -> trailing blank cell
      expect(lines[2].endsWith(','), isTrue);
    });
  });
}
