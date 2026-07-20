import 'dart:io';

import 'package:obd_battery_diagnostics/engine/diagnostics_client.dart';
import 'package:obd_battery_diagnostics/engine/signal_set.dart';
import 'package:obd_battery_diagnostics/transport/data_source.dart';
import 'package:test/test.dart';

SignalSet loadBmw() =>
    SignalSet.parse(File('signalsets/BMW-330e-2018/v01.json').readAsStringSync());

void main() {
  group('DiagnosticsClient over ReplaySource (simulated SME)', () {
    late SignalSet set;
    setUpAll(() => set = loadBmw());

    test('reads and decodes SOC end-to-end', () async {
      // Scripted SME conversation: the request line "0722DDBC" (extended addr
      // 07 + 22 DDBC) returns a single-frame response on 607.
      final source = ReplaySource({
        '0722DDBC': '607 05 62 DD BC 03 20\r>',
      });
      await source.connect();
      final client = DiagnosticsClient(source, set);
      await client.initialize();

      final soc = set.commands
          .firstWhere((c) => c.signals.any((s) => s.id == 'HVBAT_SOC'));
      final readings = await client.read(soc,
          now: DateTime.utc(2026, 1, 1));

      expect(readings, hasLength(1));
      expect(readings.single.signal.id, 'HVBAT_SOC');
      expect(readings.single.value, closeTo(80.0, 1e-9));
      expect(readings.single.unit, 'percent');

      // Verify addressing commands were issued.
      expect(source.sentLog, contains('ATSH6F1'));
      expect(source.sentLog, contains('ATCRA607'));
    });

    test('reads multi-frame cell voltages end-to-end', () async {
      // DFA0 -> 62 DF A0 <min 0F00> <max 0F10> <avg 0F08> = 8 payload bytes.
      // ISO-TP: total message = 62 DF A0 0F 00 0F 10 0F 08 (9 bytes) -> FF+CF.
      final source = ReplaySource({
        '0722DFA0': '607 10 09 62 DF A0 0F 00\r'
            '607 21 0F 10 0F 08 00 00\r>',
      });
      await source.connect();
      final client = DiagnosticsClient(source, set);

      final cmd = set.commands
          .firstWhere((c) => c.signals.any((s) => s.id == 'HVBAT_CELL_V_MIN'));
      final readings = await client.read(cmd);
      final byId = {for (final r in readings) r.signal.id: r.value};

      expect(byId['HVBAT_CELL_V_MIN'], closeTo(0.3840, 1e-9));
      expect(byId['HVBAT_CELL_V_MAX'], closeTo(0.3856, 1e-9));
      expect(byId['HVBAT_CELL_V_AVG'], closeTo(0.3848, 1e-9));
    });

    test('readAll skips failing commands via onFailure', () async {
      // Only SOC responds; everything else returns NO DATA.
      final source = ReplaySource({
        '0722DDBC': '607 05 62 DD BC 03 20\r>',
      });
      // Default (unmapped) returns the benign prompt, which parseFrames treats
      // as no frames -> CommandFailure. Make the misses explicit NO DATA.
      final failures = <CommandFailure>[];
      await source.connect();
      final client = DiagnosticsClient(source, set);
      final all = await client.readAll(onFailure: failures.add);

      expect(all.containsKey('HVBAT_SOC'), isTrue);
      expect(failures, isNotEmpty); // the other DIDs weren't scripted
    });
  });
}
