/// Replays the 12 V recharge history the 330e's DME (address 12) returned
/// on 2026-11-08 (captures/bmw_dme_2026-11-08.txt, DID 409D) through the
/// full ELM -> ISO-TP -> UDS -> formula path. The layout is the BMW i3's
/// (OVMS), re-fitted to this car; the values are NOT cross-checked against
/// another tool, so the signals are marked unconfirmed.
library;

import 'dart:io';

import 'package:obd_battery_diagnostics/engine/diagnostics_client.dart';
import 'package:obd_battery_diagnostics/engine/signal_set.dart';
import 'package:obd_battery_diagnostics/transport/data_source.dart';
import 'package:obd_battery_diagnostics/transport/simulated_source.dart';
import 'package:test/test.dart';

/// The payload bytes of `22<did> -> ..` in the DME capture.
List<int> captured(String did) {
  final line = File('captures/bmw_dme_2026-11-08.txt')
      .readAsLinesSync()
      .firstWhere((l) => l.trimLeft().startsWith('22$did -> '));
  return [
    for (final h in line.split('->')[1].trim().split(' '))
      int.parse(h, radix: 16)
  ];
}

/// UDS message -> ELM lines on 612 with BMW extended addressing.
String frame(List<int> msg) {
  String line(List<int> b) =>
      '612 ${b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ')}';
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
  final command = set.commands.singleWhere((c) => c.eax == '12');

  test('12 V history (409D) decodes from the capture', () async {
    final history = captured('409D');
    expect(history.length, 88); // 8-byte header + four 20-byte records
    final source =
        ReplaySource({'22409D': frame([0x62, 0x40, 0x9D, ...history])});
    await source.connect();
    final client = DiagnosticsClient(source, set);
    final v = {
      for (final r in await client.read(command)) r.signal.id: r.value
    };
    expect(v['LVBAT_SOC_PARK'], 99.5);
    expect(v['LVBAT_TOPUP_SOC_START'], 66.0);
    expect(v['LVBAT_TOPUP_SOC_END'], 73.5);
    // Odometer stamp of that top-up; plain km, so it follows the km/mi choice.
    expect(v['LVBAT_TOPUP_KM'], 77624);
    expect(set.signalsById['LVBAT_TOPUP_KM']!.fmt.unit, 'km');

    // Addressed to the DME with its own flow control, reply filtered to 612.
    expect(
        source.sentLog,
        containsAllInOrder(
            ['ATCEA12', 'ATFCSD12300000', 'ATFCSM1', 'ATCRA612', '22409D']));
  });

  test('the layout holds together: km stamp, clocks, histogram totals', () {
    final h = captured('409D');
    int u(int at, int n) =>
        h.sublist(at, at + n).fold(0, (a, b) => (a << 8) | b);
    expect(u(4, 3), 77698); // the odometer on the day of the capture
    // Each record: parked, then the top-up started later; newest first.
    final starts = [for (var r = 8; r < 88; r += 20) u(r + 8, 4)];
    for (var r = 8, i = 0; r < 88; r += 20, i++) {
      expect(u(r, 4), lessThan(starts[i]), reason: 'record $i');
      expect(u(r + 15, 2), closeTo(3600, 5), reason: 'about an hour');
    }
    expect(starts, orderedEquals([...starts]..sort((a, b) => b - a)));
    // 409E: 8 bins by time parked + 8 bins by top-up duration, same total.
    final bins = captured('409E');
    int sum(Iterable<int> x) => x.fold(0, (a, b) => a + b);
    expect(sum(bins.take(8)), 23);
    expect(sum(bins.skip(8)), 23);
  });

  test('marked unconfirmed, read every 5 minutes, and in the demo', () async {
    expect(command.freq, 300);
    for (final s in command.signals) {
      // The odometer stamp is plain km; the charge levels are unverified.
      expect(s.fmt.unit, s.id == 'LVBAT_TOPUP_KM' ? 'km' : 'percent?',
          reason: s.id);
      expect(s.name, contains('(unconfirmed)'), reason: s.id);
      expect(s.group, '12v');
    }
    final demo = SimulatedBmwSource();
    await demo.connect();
    final client = DiagnosticsClient(demo, set);
    await client.initialize();
    final failures = <CommandFailure>[];
    final all = await client.readAll(onFailure: failures.add);
    expect(failures, isEmpty, reason: failures.join('\n'));
    expect(all['LVBAT_SOC_PARK']!.value, 99.5);
    expect(all['HVBAT_CONTACTOR_CYCLES']!.value, 15403);
    expect(all['MOTOR_RPM']!.value, 0); // back on the EME after the DME
  });
}
