import 'dart:io';

import 'package:obd_battery_diagnostics/engine/signal_set.dart';
import 'package:obd_battery_diagnostics/protocol/uds.dart';
import 'package:test/test.dart';

/// Verifies the Lyriq battery signals confirmed on-vehicle 2026-08-14/15
/// decode the exact captured responses to the values observed on the car.
void main() {
  late SignalSet set;
  setUpAll(() => set = SignalSet.parse(
      File('signalsets/Cadillac-Lyriq-2025/v01.json').readAsStringSync()));

  double decodeFromResponse(String id, List<int> message) {
    final cmd = set.commands.firstWhere((c) => c.signals.any((s) => s.id == id));
    final resp = parseResponse(message,
        requestService: 0x22, identifierLength: 2);
    return cmd.signals.firstWhere((s) => s.id == id).fmt.decode(resp.data);
  }

  test('pack current decodes charging capture FE39 -> -22.75 A', () {
    // ECU 17, captured at 9.22 kW AC charge
    final v = decodeFromResponse('HVBAT_CURRENT', [0x62, 0x24, 0x14, 0xFE, 0x39]);
    expect(v, closeTo(-22.75, 0.001));
  });

  test('pack current decodes Ready aux-draw capture 0012 -> +0.9 A', () {
    final v = decodeFromResponse('HVBAT_CURRENT', [0x62, 0x24, 0x14, 0x00, 0x12]);
    expect(v, closeTo(0.9, 0.001));
  });

  test('nominal pack voltage decodes 5806 -> 352.09 V', () {
    final v = decodeFromResponse(
        'HVBAT_NOMINAL_VOLTAGE', [0x62, 0x24, 0x29, 0x58, 0x06]);
    expect(v, closeTo(352.09, 0.01));
  });

  test('odometer decodes 001EFE52 -> 31737.3 km (= dash 19,720 mi)', () {
    final v = decodeFromResponse(
        'ODOMETER', [0x62, 0x44, 0x8F, 0x00, 0x1E, 0xFE, 0x52]);
    expect(v, closeTo(31737.28, 0.1));
    expect(v / 1.609344, closeTo(19720, 1)); // matches the dash in miles
  });

  test('EVSE pilot decodes 0184 -> 38.8 A (9.3 kW EVSE) and 0064 -> 10.0 A', () {
    expect(decodeFromResponse('EVSE_PILOT_CURRENT', [0x62, 0x41, 0x49, 0x01, 0x84]),
        closeTo(38.8, 0.001));
    expect(decodeFromResponse('EVSE_PILOT_CURRENT', [0x62, 0x41, 0x49, 0x00, 0x64]),
        closeTo(10.0, 0.001));
  });

  test('12V rail decodes 0x85 -> 13.3 V (33E5 correction)', () {
    final v = decodeFromResponse('LV_RAIL_VOLTAGE', [0x62, 0x33, 0xE5, 0x85]);
    expect(v, closeTo(13.3, 0.001));
  });

  test('battery signals present, grouped, and addressed to the right ECUs', () {
    final current = set.commands
        .firstWhere((c) => c.signals.any((s) => s.id == 'HVBAT_CURRENT'));
    expect(current.hdr, '18DA17F1');
    expect(current.rax, '18DAF117');
    final odo = set.commands
        .firstWhere((c) => c.signals.any((s) => s.id == 'ODOMETER'));
    expect(odo.hdr, '18DA40F1');
    expect(set.signalsById['HVBAT_CURRENT']!.group, 'summary');
    expect(set.signalsById['EVSE_PILOT_CURRENT']!.group, 'charging');
    // The wrong pack-voltage signal must be gone.
    expect(set.signalsById.containsKey('HVBAT_PACK_VOLTAGE'), isFalse);
  });
}
