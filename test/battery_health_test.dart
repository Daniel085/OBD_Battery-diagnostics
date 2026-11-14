import 'dart:convert';

import 'package:obd_battery_diagnostics/engine/battery_health.dart';
import 'package:obd_battery_diagnostics/engine/diagnostics_client.dart';
import 'package:obd_battery_diagnostics/engine/display_units.dart';
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

    group('cell imbalance is graded only near rest', () {
      // The 2026-11-14 BMW read: 79 mV spread while drawing 12.5 A in Drive.
      Map<String, Reading> pack(double? amps) => {
            'HVBAT_CELL_V_MIN': _r('HVBAT_CELL_V_MIN', 'min', 3.473, 'volts'),
            'HVBAT_CELL_V_MAX': _r('HVBAT_CELL_V_MAX', 'max', 3.552, 'volts'),
            if (amps != null)
              'HVBAT_CURRENT': _r('HVBAT_CURRENT', 'I', amps, 'amps'),
          };
      HealthReport run(double? amps) =>
          analyzer.analyze(vehicle: 'v', readings: pack(amps), now: at);

      test('under load, either direction: reported, not graded', () {
        for (final amps in [12.5, -12.5, 2.0]) {
          final r = run(amps);
          expect(r.overallSeverity, Severity.info, reason: '$amps A');
          final w = r.warnings.single;
          expect(w.code, 'CELL_IMBALANCE_UNDER_LOAD');
          expect(w.message, contains('79.0 mV'));
          expect(w.message, contains('${amps.abs().toStringAsFixed(1)} A'));
          // The measurement itself is still in the report.
          expect(r.metrics['cell_imbalance_volts'], closeTo(0.079, 1e-9));
          expect(r.metrics['pack_current_amps'], amps);
        }
      });

      test('near rest: the same spread is critical', () {
        for (final amps in [0.0, 1.5, -1.9]) {
          final r = run(amps);
          expect(r.overallSeverity, Severity.critical, reason: '$amps A');
          expect(r.warnings.single.code, 'CELL_IMBALANCE_HIGH');
        }
      });

      test('no current signal: load unknown, graded as read', () {
        final r = run(null);
        expect(r.overallSeverity, Severity.critical);
        expect(r.metrics.containsKey('pack_current_amps'), isFalse);
      });

      test('a healthy spread under load says nothing', () {
        final r = analyzer.analyze(vehicle: 'v', now: at, readings: {
          'HVBAT_CELL_V_MIN': _r('HVBAT_CELL_V_MIN', 'min', 3.646, 'volts'),
          'HVBAT_CELL_V_MAX': _r('HVBAT_CELL_V_MAX', 'max', 3.656, 'volts'),
          'HVBAT_CURRENT': _r('HVBAT_CURRENT', 'I', -11.0, 'amps'),
        });
        expect(r.overallSeverity, Severity.ok);
      });
    });

    test('temperature warning text follows the display unit', () {
      final readings = {
        'HVBAT_CELLTEMP_MIN':
            _r('HVBAT_CELLTEMP_MIN', 'tmin', 20, 'celsius', 'temperature'),
        'HVBAT_CELLTEMP_MAX':
            _r('HVBAT_CELLTEMP_MAX', 'tmax', 35, 'celsius', 'temperature'),
      };
      final c = analyzer.analyze(vehicle: 'x', readings: readings, now: at);
      final f = analyzer.analyze(
          vehicle: 'x',
          readings: readings,
          now: at,
          units: const DisplayUnits(temperature: TemperatureUnit.fahrenheit));
      String msg(HealthReport r) =>
          r.warnings.singleWhere((w) => w.code == 'TEMP_SPREAD').message;
      expect(msg(c), contains('15.0 °C'));
      // A 15 °C spread is 27 °F: scaled, no +32 offset.
      expect(msg(f), contains('27.0 °F'));
      // Same verdict and the same Celsius metric either way.
      expect(f.overallSeverity, c.overallSeverity);
      expect(f.metrics['temp_spread_celsius'], 15);
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
