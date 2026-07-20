import 'dart:io';

import 'package:obd_battery_diagnostics/engine/signal_set.dart';
import 'package:obd_battery_diagnostics/protocol/isotp.dart';
import 'package:obd_battery_diagnostics/protocol/uds.dart';
import 'package:test/test.dart';

void main() {
  group('UDS response parsing', () {
    test('parses a positive 0x22 response and strips the DID', () {
      // Response to 22 DDBC: 62 DD BC 03 20  (SOC raw 0x0320)
      final r = parseResponse(
        [0x62, 0xDD, 0xBC, 0x03, 0x20],
        requestService: 0x22,
        identifierLength: 2,
      );
      expect(r.service, 0x62);
      expect(r.identifier, [0xDD, 0xBC]);
      expect(r.data, [0x03, 0x20]);
    });

    test('throws a named negative response', () {
      // 7F 22 31 -> requestOutOfRange for service 0x22
      expect(
        () => parseResponse([0x7F, 0x22, 0x31],
            requestService: 0x22, identifierLength: 2),
        throwsA(isA<UdsNegativeResponse>()
            .having((e) => e.nrc, 'nrc', 0x31)
            .having((e) => e.nrcName, 'name', 'requestOutOfRange')),
      );
    });

    test('flags response-pending (0x78) as pending', () {
      try {
        parseResponse([0x7F, 0x22, 0x78],
            requestService: 0x22, identifierLength: 2);
        fail('should have thrown');
      } on UdsNegativeResponse catch (e) {
        expect(e.isPending, isTrue);
      }
    });

    test('rejects a mismatched service echo', () {
      expect(
        () => parseResponse([0x50, 0xDD, 0xBC],
            requestService: 0x22, identifierLength: 2),
        throwsFormatException,
      );
    });
  });

  group('BMW 330e signal set — end-to-end decode', () {
    late SignalSet set;

    setUpAll(() {
      final file = File('signalsets/BMW-330e-2018/v01.json');
      set = SignalSet.parse(file.readAsStringSync());
    });

    test('loads and exposes expected signals', () {
      expect(set.vehicle, 'BMW-330e-2018');
      expect(set.protocol.canFormat, CanFormat.bits11);
      final ids = set.signalsById.keys.toSet();
      expect(
        ids,
        containsAll([
          'HVBAT_SOH',
          'HVBAT_SOC',
          'HVBAT_VOLTAGE',
          'HVBAT_CURRENT',
          'HVBAT_CELLTEMP_MIN',
          'HVBAT_CELLTEMP_MAX',
          'HVBAT_CELL_V_MIN',
          'HVBAT_CELL_V_MAX',
          'HVBAT_CELL_V_AVG',
        ]),
      );
    });

    test('SOC command produces the right request bytes', () {
      final soc = set.commands.firstWhere(
          (c) => c.signals.any((s) => s.id == 'HVBAT_SOC'));
      expect(soc.service, '22');
      expect(soc.payload, 'DDBC');
      expect(soc.requestBytes(), [0x22, 0xDD, 0xBC]);
      expect(soc.hdr, '6F1');
      expect(soc.rax, '607');
    });

    test('decodes SOC through ISO-TP + UDS + formula', () {
      final soc = set.commands
          .firstWhere((c) => c.signals.any((s) => s.id == 'HVBAT_SOC'));
      // Simulated SME single-frame response: 62 DD BC 03 20 (raw 0x0320 = 800).
      final frame = [0x05, 0x62, 0xDD, 0xBC, 0x03, 0x20, 0x00, 0x00];
      final message = reassemble([frame]);
      final resp = parseResponse(message,
          requestService: 0x22, identifierLength: 2);
      final signal = soc.signals.single;
      final value = signal.fmt.decode(resp.data);
      expect(value, closeTo(80.0, 1e-9)); // 800 / 10 = 80 %
      expect(signal.fmt.unit, 'percent');
    });

    test('decodes min/max cell voltages from a multi-value response', () {
      final cmd = set.commands
          .firstWhere((c) => c.signals.any((s) => s.id == 'HVBAT_CELL_V_MIN'));
      // 62 DFA0 <min:0F00=3840> <max:0F10=3856> <avg:0F08=3848>
      final message = [
        0x62, 0xDF, 0xA0, //
        0x0F, 0x00, 0x0F, 0x10, 0x0F, 0x08,
      ];
      final resp = parseResponse(message,
          requestService: 0x22, identifierLength: 2);
      final min = cmd.signals
          .firstWhere((s) => s.id == 'HVBAT_CELL_V_MIN')
          .fmt
          .decode(resp.data);
      final max = cmd.signals
          .firstWhere((s) => s.id == 'HVBAT_CELL_V_MAX')
          .fmt
          .decode(resp.data);
      expect(min, closeTo(0.3840, 1e-9));
      expect(max, closeTo(0.3856, 1e-9));
    });
  });
}
