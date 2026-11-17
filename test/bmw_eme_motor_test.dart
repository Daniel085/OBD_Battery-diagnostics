/// BMW 330e electric-motor signals (EME, address 3A): temperatures, speed
/// and torque, decoded with the BMW i3 EME layout.
///
/// NOT a capture: the frames here are built by hand from the i3 layout. They
/// check the addressing and the arithmetic, not that the car answers this
/// way. The car's own replies (parked and charging, 2026-11-15) are replayed
/// in test/bmw_charging_capture_test.dart; speed and torque with the motor
/// turning have still not been read on the car.
library;

import 'dart:io';

import 'package:obd_battery_diagnostics/engine/diagnostics_client.dart';
import 'package:obd_battery_diagnostics/engine/signal_set.dart';
import 'package:obd_battery_diagnostics/transport/data_source.dart';
import 'package:test/test.dart';

/// UDS message -> ELM lines on 63A with BMW extended addressing.
String frame(List<int> msg) {
  String line(List<int> b) =>
      '63A ${b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ')}';
  if (msg.length <= 6) return '${line([0xF1, msg.length, ...msg])}\r>';
  final lines = [
    line([0xF1, 0x10 | (msg.length >> 8), msg.length & 0xFF, ...msg.take(5)])
  ];
  var seq = 1;
  for (var i = 5; i < msg.length; i += 6) {
    lines.add(line([0xF1, 0x20 | (seq++ & 0x0F), ...msg.skip(i).take(6)]));
  }
  return '${lines.join('\r')}\r>';
}

void main() {
  final set = SignalSet.parse(
      File('signalsets/BMW-330e-2018/v02.json').readAsStringSync());
  final motor = [
    for (final c in set.commands)
      if (c.signals.any((s) => s.id.startsWith('MOTOR_'))) c
  ];

  Future<Map<String, double>> read(Map<String, String> script,
      {ReplaySource? source}) async {
    final src = source ?? ReplaySource(script);
    await src.connect();
    final client = DiagnosticsClient(src, set);
    return {
      for (final c in motor)
        for (final r in await client.read(c)) r.signal.id: r.value,
    };
  }

  test('the motor commands address the EME (3A) and listen on 63A', () async {
    expect(motor.map((c) => c.payload), ['DEA6', 'DEA7']);
    final src = ReplaySource({
      '22DEA6': frame([0x62, 0xDE, 0xA6, 0x09, 0xED, 0x0A, 0x6D]),
      '22DEA7': frame(
          [0x62, 0xDE, 0xA7, 0x27, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00]),
    });
    await read(const {}, source: src);
    expect(
        src.sentLog,
        containsAllInOrder(
            ['ATCEA3A', 'ATFCSD3A300000', 'ATFCSM1', 'ATCRA63A', '22DEA6']));
    // Same ECU for the second command: no re-addressing in between.
    final between = src.sentLog
        .sublist(src.sentLog.indexOf('22DEA6') + 1, src.sentLog.indexOf('22DEA7'));
    expect(between, isEmpty);
  });

  test('parked, warm motor: the BimmerLink 2026-11-08 values', () async {
    // 39.7 / 41.7 degC = raw 2541 / 2669 at 1/64 degC. Speed raw 10000 is
    // 0 rpm (x 0.5 - 5000). Both replies are multi-frame under extended
    // addressing (more than 6 bytes).
    final v = await read({
      '22DEA6': frame([0x62, 0xDE, 0xA6, 0x09, 0xED, 0x0A, 0x6D]),
      '22DEA7': frame(
          [0x62, 0xDE, 0xA7, 0x27, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00]),
    });
    expect(v['MOTOR_TEMP_1'], closeTo(39.70, 0.01));
    expect(v['MOTOR_TEMP_2'], closeTo(41.70, 0.01));
    expect(v['MOTOR_RPM'], 0);
    expect(v['MOTOR_TORQUE'], 0);
    expect(v['MOTOR_TORQUE_TARGET'], 0);
  });

  test('driving and regen: speed offset and signed torque', () async {
    // 1500 rpm = raw 13000; +80.5 Nm = raw 161; target -100 Nm = raw -200.
    final v = await read({
      '22DEA6': frame([0x62, 0xDE, 0xA6, 0xFF, 0xC0, 0x00, 0x40]),
      '22DEA7': frame(
          [0x62, 0xDE, 0xA7, 0x32, 0xC8, 0x00, 0xA1, 0xFF, 0x38, 0x01]),
    });
    expect(v['MOTOR_RPM'], 1500);
    expect(v['MOTOR_TORQUE'], 80.5);
    expect(v['MOTOR_TORQUE_TARGET'], -100);
    expect(v['MOTOR_TEMP_1'], -1); // below freezing: the field is signed
    expect(v['MOTOR_TEMP_2'], 1);
  });

  test('the motor signals stay marked unverified until read on the car', () {
    for (final c in motor) {
      for (final s in c.signals) {
        expect(s.fmt.unit, endsWith('?'), reason: s.id);
      }
    }
  });
}
