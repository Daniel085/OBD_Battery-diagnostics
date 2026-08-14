import 'dart:io';

import 'package:obd_battery_diagnostics/engine/signal_set.dart';
import 'package:obd_battery_diagnostics/protocol/uds.dart';
import 'package:test/test.dart';

/// Verifies the Lyriq dynamics signals decode to the values OBDb's sample
/// responses expect — the formulas were derived from those exact captures.
void main() {
  late SignalSet set;
  setUpAll(() => set = SignalSet.parse(
      File('signalsets/Cadillac-Lyriq-2025/v01.json').readAsStringSync()));

  Signal sig(String id) => set.signalsById[id]!;

  double decodeFromResponse(String id, List<int> message) {
    final cmd = set.commands.firstWhere((c) => c.signals.any((s) => s.id == id));
    final resp = parseResponse(message,
        requestService: 0x22, identifierLength: 2);
    return cmd.signals.firstWhere((s) => s.id == id).fmt.decode(resp.data);
  }

  test('wheel speeds decode 0x64 -> 100 km/h on all four corners', () {
    // OBDb: 62 4A7A 64 64 64 64  -> all 100
    final msg = [0x62, 0x4A, 0x7A, 0x64, 0x64, 0x64, 0x64];
    expect(decodeFromResponse('WHEEL_SPEED_FL', msg), 100);
    expect(decodeFromResponse('WHEEL_SPEED_FR', msg), 100);
    expect(decodeFromResponse('WHEEL_SPEED_RL', msg), 100);
    expect(decodeFromResponse('WHEEL_SPEED_RR', msg), 100);
  });

  test('lateral acceleration matches OBDb sample FF50 -> -0.28033 g', () {
    // 62 4C2F FF 50
    final v = decodeFromResponse('ACCEL_LATERAL', [0x62, 0x4C, 0x2F, 0xFF, 0x50]);
    expect(v, closeTo(-0.28033, 0.001));
  });

  test('longitudinal acceleration matches OBDb sample FF68 -> -0.24211 g', () {
    final v =
        decodeFromResponse('ACCEL_LONGITUDINAL', [0x62, 0x4C, 0x30, 0xFF, 0x68]);
    expect(v, closeTo(-0.24211, 0.001));
  });

  test('dynamics + odometer signals are present and grouped', () {
    for (final id in [
      'WHEEL_SPEED_FL',
      'ACCEL_LATERAL',
      'ACCEL_LONGITUDINAL',
      'STEERING_ANGLE',
      'ODOMETER',
    ]) {
      expect(set.signalsById.containsKey(id), isTrue, reason: 'missing $id');
    }
    expect(sig('ODOMETER').group, 'vehicle');
    expect(sig('ACCEL_LATERAL').group, 'dynamics');
  });
}
