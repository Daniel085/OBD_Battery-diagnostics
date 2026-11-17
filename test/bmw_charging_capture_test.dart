/// Replays what the 330e returned on 2026-11-15 while plugged in and charging
/// (captures/bmw_2026-11-15.txt: SME 07, DME 12 and EME 3A, read through the
/// Pi with tools/bmw-sme-probe/sme_probe.py --no-gate) through the full
/// ELM -> ISO-TP -> UDS -> formula path with the v02 signal set.
///
/// This is the second on-car read of the ageing figures and the 12 V history
/// (first: 2026-11-08) and the first of the EME motor values.
library;

import 'dart:io';

import 'package:obd_battery_diagnostics/engine/diagnostics_client.dart';
import 'package:obd_battery_diagnostics/engine/signal_set.dart';
import 'package:obd_battery_diagnostics/transport/data_source.dart';
import 'package:test/test.dart';

const capture = 'captures/bmw_2026-11-15.txt';

/// `22xxxx -> payload` lines per ECU section, re-framed as that ECU's reply
/// (BMW extended addressing: F1 address byte, ISO-TP, 62 + DID + payload).
Map<String, String> capturedReplies() {
  final out = <String, String>{};
  var ecu = 0x07;
  final section = RegExp(r'^== (?:SME \((\w\w)\)|ECU (\w\w) read)');
  final read = RegExp(r'^\s+22([0-9A-F]{4})\s+-> ((?:[0-9a-f]{2} ?)+)$');
  for (final line in File(capture).readAsLinesSync()) {
    final s = section.firstMatch(line);
    if (s != null) {
      ecu = int.parse(s.group(1) ?? s.group(2)!, radix: 16);
      continue;
    }
    final m = read.firstMatch(line);
    if (m == null) continue;
    final did = m.group(1)!;
    final payload = [
      for (final h in m.group(2)!.trim().split(' ')) int.parse(h, radix: 16)
    ];
    out.putIfAbsent(
        '22$did',
        () => _frame(0x600 + ecu, [
              0x62,
              int.parse(did.substring(0, 2), radix: 16),
              int.parse(did.substring(2), radix: 16),
              ...payload
            ]));
  }
  return out;
}

String _frame(int canId, List<int> msg) {
  String line(List<int> b) => '${canId.toRadixString(16).toUpperCase()} '
      '${b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ')}';
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
  late SignalSet set;
  late Map<String, Reading> all;
  late List<CommandFailure> failures;

  setUpAll(() async {
    set = SignalSet.parse(
        File('signalsets/BMW-330e-2018/v02.json').readAsStringSync());
    final source = ReplaySource(capturedReplies());
    await source.connect();
    final client = DiagnosticsClient(source, set);
    failures = [];
    all = await client.readAll(onFailure: failures.add);
  });

  double? v(String id) => all[id]?.value;

  test('only reads the probe did not make are missing', () {
    // J1979 is silent while the car charges; the probe's standard set does
    // not include pack voltage (DD66) or the module defect codes (DFA6).
    final missing = {
      for (final f in failures) '${f.command.service}${f.command.payload}'
    };
    expect(missing.where((m) => m.startsWith('22')), ['22DD66', '22DFA6'],
        reason: failures.join('\n'));
  });

  test('battery state while charging', () {
    expect(v('HVBAT_SOC'), closeTo(9.0, 1e-9));
    expect(v('HVBAT_SOH'), 83);
    // Raw +11.21 A is charge; the app's convention is negative = charge.
    expect(v('HVBAT_CURRENT'), closeTo(-11.21, 1e-9));
  });

  test('ageing and lifetime figures, second read', () {
    expect(v('HVBAT_SOH_RESISTANCE'), closeTo(62.7, 1e-9)); // 62.8 on 11-08
    expect(v('HVBAT_ISOLATION'), 2000);
    expect(v('HVBAT_HV_ON_HOURS'), 10600); // 10594 on 11-08
    expect(v('HVBAT_CONTACTOR_CYCLES'), 15435); // 15403 on 11-08
    expect(v('HVBAT_CONTACTOR_CYCLES_LOAD'), 0);
  });

  test('battery age counts wall-clock hours, so it is no longer marked', () {
    // 78034 h at ~14:15 on 2026-11-08, 78200 h at 12:27 on 2026-11-15:
    // +166 h in 166.2 h of real time.
    expect(v('HVBAT_AGE_HOURS'), 78200);
    final sinceFirstRead = DateTime(2026, 11, 15, 12, 27)
        .difference(DateTime(2026, 11, 8, 14, 15))
        .inHours;
    expect(78200 - 78034, sinceFirstRead);
    final age = all['HVBAT_AGE_HOURS']!.signal;
    expect(age.fmt.unit, 'hours');
    expect(age.name, isNot(contains('unconfirmed')));
  });

  test('12 V history: new park header, same four top-ups', () {
    expect(v('LVBAT_SOC_PARK'), 88.5); // 99.5 on 11-08
    expect(v('LVBAT_TOPUP_SOC_START'), 66.0);
    expect(v('LVBAT_TOPUP_SOC_END'), 73.5);
    expect(v('LVBAT_TOPUP_KM'), 77624); // same record as on 11-08
  });

  test('motor temperatures after a drive; raw-zero speed is not shown', () {
    final temps = [
      for (final e in all.entries)
        if (e.key.startsWith('MOTOR_') && e.value.unit.startsWith('celsius'))
          e.value.value
    ];
    expect(temps, hasLength(2));
    expect(temps[0], closeTo(53.3, 0.1));
    expect(temps[1], closeTo(55.3, 0.1));
    // 00 00 in the speed field would decode to -5000 rpm.
    expect(all.containsKey('MOTOR_RPM'), isFalse);
    expect(v('MOTOR_TORQUE'), 0);
  });

  test('lifetime charge counters (little-endian ampere-seconds)', () {
    expect(v('HVBAT_AH_CHARGED'), closeTo(34048.86, 0.01)); // 34,021 on 11-08
    expect(v('HVBAT_AH_DISCHARGED'), closeTo(33173.13, 0.01)); // 33,136
    expect(all['HVBAT_AH_CHARGED']!.unit, 'amp_hours');
    expect(all['HVBAT_AH_DISCHARGED']!.unit, 'amp_hours?');
  });

  chargeLogTests();
}

/// The plug-in charge of 2026-11-15 (captures/bmw_chg_2026-11-15.txt,
/// tools/bmw-sme-probe/sme_chglog.py): pack current every ~26 s, the
/// counter set every ~10 minutes. Decoded with the signal set's own formats.
class ChargeLog {
  /// (seconds of day, DID -> payload) for the fast rows and the slow rows.
  final fast = <(int, Map<String, List<int>>)>[];
  final slow = <(int, Map<String, List<int>>)>[];

  ChargeLog(String path) {
    final row = RegExp(r'^(\d\d):(\d\d):(\d\d)( SLOW| AFTER| FINAL)? (\S+=.*)$');
    for (final line in File(path).readAsLinesSync()) {
      final m = row.firstMatch(line);
      if (m == null) continue;
      final t = int.parse(m.group(1)!) * 3600 +
          int.parse(m.group(2)!) * 60 +
          int.parse(m.group(3)!);
      final values = <String, List<int>>{};
      for (final kv in m.group(5)!.split(' ')) {
        final [did, hex] = kv.split('=');
        if (hex == '-') continue;
        values[did] = [
          for (var i = 0; i < hex.length; i += 2)
            int.parse(hex.substring(i, i + 2), radix: 16)
        ];
      }
      (m.group(4) == null ? fast : slow).add((t, values));
    }
  }
}

void chargeLogTests() {
  final set = SignalSet.parse(
      File('signalsets/BMW-330e-2018/v02.json').readAsStringSync());
  final log = ChargeLog('captures/bmw_chg_2026-11-15.txt');
  double decode(String id, List<int> payload) =>
      set.signalsById[id]!.fmt.decode(payload);

  // Pack current over time; the app's sign is negative = charge.
  final current = [
    for (final (t, v) in log.fast)
      if (v['DD69'] case final p?) (t, -decode('HVBAT_CURRENT', p))
  ];

  /// Ampere-hours that flowed in between two times (trapezoid rule).
  double ampHours(int from, int to) {
    var sum = 0.0;
    for (var i = 1; i < current.length; i++) {
      final (t0, a0) = current[i - 1];
      final (t1, a1) = current[i];
      final lo = t0 > from ? t0 : from;
      final hi = t1 < to ? t1 : to;
      if (hi <= lo) continue;
      double at(int t) => a0 + (a1 - a0) * (t - t0) / (t1 - t0);
      sum += (at(lo) + at(hi)) / 2 * (hi - lo) / 3600;
    }
    return sum;
  }

  test('the charge-in counter (DD73) counts the pack current', () {
    // From 12:47 on the log is unbroken (two short pauses before that).
    final reads = [
      for (final (t, v) in log.slow)
        if (t >= 12 * 3600 + 47 * 60)
          if (v['DD73'] case final p?) (t, decode('HVBAT_AH_CHARGED', p))
    ];
    expect(reads.length, greaterThanOrEqualTo(7));
    for (var i = 1; i < reads.length; i++) {
      final counted = reads[i].$2 - reads[i - 1].$2;
      final measured = ampHours(reads[i - 1].$1, reads[i].$1);
      expect(counted, closeTo(measured, measured * 0.015), reason: 'step $i');
    }
    final counted = reads.last.$2 - reads.first.$2;
    final measured = ampHours(reads.first.$1, reads.last.$1);
    expect(counted, closeTo(9.58, 0.01)); // Ah in 73 minutes
    expect(counted, closeTo(measured, measured * 0.002));
  });

  test('the charge-out counter (DD74) stands still while charging', () {
    final out = {
      for (final (_, v) in log.slow)
        if (v['DD74'] case final p?) decode('HVBAT_AH_DISCHARGED', p)
    };
    expect(out, hasLength(1));
    expect(out.single, closeTo(33173.13, 0.01));
  });

  test('16.2 Ah per 100 % of SOC, steady through the charge', () {
    final soc = [
      for (final (t, v) in log.fast)
        if (v['DDBC'] case final p?) (t, decode('HVBAT_SOC', p))
    ];
    (int, double) at(int h, int m) =>
        soc.firstWhere((s) => s.$1 >= h * 3600 + m * 60);
    for (final (from, to) in [
      (at(12, 47), at(13, 30)), // constant current
      (at(13, 30), at(14, 3)), // taper
      (at(12, 47), at(14, 3)),
    ]) {
      final perPoint = ampHours(from.$1, to.$1) / (to.$2 - from.$2);
      expect(perPoint * 100, closeTo(16.2, 0.3));
    }
  });
}
