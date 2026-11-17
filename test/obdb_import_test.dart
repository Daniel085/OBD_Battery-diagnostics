/// Vehicles imported from OBDb (tools/obdb-import): replays the replies
/// OBDb contributors captured on real vehicles (test/fixtures/obdb/*.json,
/// built from OBDb's tests/test_cases) through the full ELM -> ISO-TP -> UDS
/// -> formula path and checks the values OBDb expects from them.
///
/// This proves the import and this app's decoder agree with OBDb. It does
/// not prove a signal means what OBDb says it means on every truck.
library;

import 'dart:convert';
import 'dart:io';

import 'package:obd_battery_diagnostics/app/signal_set_repository.dart';
import 'package:obd_battery_diagnostics/engine/battery_health.dart';
import 'package:obd_battery_diagnostics/engine/diagnostics_client.dart';
import 'package:obd_battery_diagnostics/engine/signal_set.dart';
import 'package:obd_battery_diagnostics/transport/data_source.dart';
import 'package:test/test.dart';

void main() {
  final fixtures = Directory('test/fixtures/obdb')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('every imported vehicle has fixtures and is in the catalogue', () {
    final imported = SignalSetRepository.catalogue
        .where((v) => v.id.startsWith('Ford-'))
        .toList();
    expect(imported, hasLength(2));
    for (final v in imported) {
      expect(File(v.assetPath).existsSync(), isTrue, reason: v.assetPath);
      expect(File('test/fixtures/obdb/${v.id}.json').existsSync(), isTrue);
      expect(v.note, contains('OBDb'));
    }
  });

  for (final file in fixtures) {
    final fx = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final vehicle = fx['vehicle'] as String;
    final set =
        SignalSet.parse(File(fx['signalSet'] as String).readAsStringSync());
    final cases = (fx['cases'] as List).cast<Map<String, dynamic>>();

    group(vehicle, () {
      test("OBDb's captured replies decode to OBDb's values", () async {
        expect(cases, isNotEmpty);
        var checked = 0;
        for (final c in cases) {
          final command = set.commands.singleWhere((x) =>
              x.hdr == c['hdr'] && '${x.service}${x.payload}' == c['request']);
          final source =
              ReplaySource({c['request'] as String: '${c['response']}\r>'});
          await source.connect();
          final client = DiagnosticsClient(source, set);
          final got = {
            for (final r in await client.read(command)) r.signal.id: r
          };
          final why = '${c['year']} ${c['hdr']} ${c['request']} '
              '<- ${c['response']}';
          (c['expected'] as Map<String, dynamic>).forEach((id, want) {
            final r = got[id];
            if (want == null) {
              // OBDb: this reply means "no value".
              expect(r, isNull, reason: '$id $why');
            } else if (want is String) {
              expect(r?.signal.fmt.labelFor(r.value), want,
                  reason: '$id $why');
            } else {
              expect(r, isNotNull, reason: '$id $why');
              final w = (want as num).toDouble();
              expect(r!.value, closeTo(w, 1e-6 + w.abs() * 1e-6),
                  reason: '$id $why');
            }
            checked++;
          });
        }
        expect(checked, greaterThanOrEqualTo(cases.length));
      });

      test('ids are unique and requests are reads only', () {
        final ids = [
          for (final c in set.commands)
            for (final s in c.signals) s.id
        ];
        expect(ids.toSet().length, ids.length);
        for (final c in set.commands) {
          expect(c.service, '22', reason: c.payload);
          expect(c.hdr, isNotNull);
        }
      });
    });
  }

  group('Ford-F-150-Lightning-2022', () {
    final set = SignalSet.parse(
        File('signalsets/Ford-F-150-Lightning-2022/v01.json')
            .readAsStringSync());

    test('the signals the app looks for are there, on the battery ECU', () {
      final byId = {
        for (final c in set.commands)
          for (final s in c.signals) s.id: c
      };
      for (final id in [
        'HVBAT_SOC',
        'HVBAT_SOH',
        'HVBAT_VOLTAGE',
        'HVBAT_CURRENT',
        'HVBAT_CELLTEMP_MIN',
        'HVBAT_CELLTEMP_MAX',
        'HVBAT_AH_DISCHARGED',
        'HVBAT_CAPACITY_AH',
      ]) {
        expect(byId[id]?.hdr, '7E4', reason: id);
        expect(byId[id]?.rax, '7EC', reason: id);
      }
      expect(byId['MOTOR_RPM']?.hdr, '7E6');
      expect(byId['LVBAT_SOC']?.hdr, '726');
      // No pack data in the set: no capacity test, cycles from the car's own
      // capacity figure.
      expect(set.ratedKwh, isNull);
      expect(set.ratedAh, isNull);
    });

    test('cycle count from the capacity the truck reports', () {
      // OBDb's 2023 captures: 373.9 Ah capacity, 60,290 Ah lifetime out.
      Reading r(String id, double v) =>
          Reading(set.signalsById[id]!, v, DateTime(2026));
      final c = BatteryHealthAnalyzer.equivalentFullCycles({
        'HVBAT_CAPACITY_AH': r('HVBAT_CAPACITY_AH', 373.9),
        'HVBAT_AH_DISCHARGED': r('HVBAT_AH_DISCHARGED', 60290),
      }, set.ratedAh)!;
      expect(c.cycles, closeTo(161.2, 0.1));
      expect(c.capacityReported, isTrue);
      expect(c.confirmed, isTrue);
    });
  });

  group('Ford-F-150-Hybrid-2021', () {
    final set = SignalSet.parse(
        File('signalsets/Ford-F-150-Hybrid-2021/v01.json').readAsStringSync());

    test('every hybrid-battery signal is marked unconfirmed', () {
      final hv = [
        for (final c in set.commands)
          if (c.hdr == '7E4') ...c.signals
      ];
      expect(hv, isNotEmpty);
      for (final s in hv) {
        expect(s.name, contains('(unconfirmed)'), reason: s.id);
        if (s.fmt.unit != null) {
          expect(s.fmt.unit, endsWith('?'), reason: s.id);
        }
      }
      // The parts OBDb does have for the F-150 are not marked.
      expect(set.signalsById['LVBAT_SOC']!.fmt.unit, 'percent');
      expect(set.signalsById['LVBAT_AGE_HOURS']!.fmt.unit, 'hours');
    });
  });
}
