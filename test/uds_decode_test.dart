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
      final file = File('signalsets/BMW-330e-2018/v02.json');
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
          'HVBAT_SOC_WINDOW_MAX',
          'HVBAT_SOC_WINDOW_MIN',
          'HVBAT_CURRENT',
          'HVBAT_CELLTEMP_MIN',
          'HVBAT_CELLTEMP_MAX',
          'HVBAT_CELL_V_MIN',
          'HVBAT_CELL_V_MAX',
          'HVBAT_CELL_V_AVG',
          'HVBAT_CELL_SOC_MIN',
          'HVBAT_CELL_SOC_MAX',
          'HVBAT_CELL_SOC_AVG',
        ]),
      );
      expect(ids, contains('HVBAT_VOLTAGE')); // F30: DD66 (i3's DD68 absent)
      expect(set.commands.any((c) => c.payload == 'DD68'), isFalse);
    });

    test('SOC command produces the right request bytes', () {
      final soc = set.commands
          .firstWhere((c) => c.signals.any((s) => s.id == 'HVBAT_SOC'));
      expect(soc.service, '22');
      expect(soc.payload, 'DDBC');
      expect(soc.requestBytes(), [0x22, 0xDD, 0xBC]);
      expect(soc.hdr, '6F1');
      expect(soc.rax, '607');
    });

    test('decodes SOC + window bounds through ISO-TP + UDS + formula', () {
      final soc = set.commands
          .firstWhere((c) => c.signals.any((s) => s.id == 'HVBAT_SOC'));
      // On-vehicle 2026-11-08 (F1 address byte already stripped):
      // FF 10 09 62 DD BC 03 8B, CF 21 03 0C 00 F6.
      final message = reassemble([
        [0x10, 0x09, 0x62, 0xDD, 0xBC, 0x03, 0x8B],
        [0x21, 0x03, 0x0C, 0x00, 0xF6, 0xFF, 0xFF],
      ]);
      final resp =
          parseResponse(message, requestService: 0x22, identifierLength: 2);
      double v(String id) =>
          soc.signals.firstWhere((s) => s.id == id).fmt.decode(resp.data);
      expect(v('HVBAT_SOC'), closeTo(90.7, 1e-9));
      expect(v('HVBAT_SOC_WINDOW_MAX'), closeTo(78.0, 1e-9));
      expect(v('HVBAT_SOC_WINDOW_MIN'), closeTo(24.6, 1e-9));
    });
  });
}
