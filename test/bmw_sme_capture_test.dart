/// Replays the real 2026-11-08 BMW 330e SME reads (captures/bmw_sme_2026-11-08.txt,
/// probe round 3, round 1) through the full ELM -> ISO-TP -> UDS -> formula
/// path with the v02 signal set. Values are what the car reported; the
/// BimmerLink cross-checks are in docs/bmw-330e-sme.md.
library;

import 'dart:io';

import 'package:obd_battery_diagnostics/engine/diagnostics_client.dart';
import 'package:obd_battery_diagnostics/engine/signal_set.dart';
import 'package:obd_battery_diagnostics/transport/data_source.dart';
import 'package:test/test.dart';

/// Pull `22xxxx -> ...` lines from the probe-3 section onward, keeping the
/// first occurrence of each request. Probe 3 logged raw ELM frames
/// (`607F1...`); the canonical sme_probe.py logs the decoded payload
/// (`7b 5f`), which is re-framed here as the SME's reply (F1 address byte,
/// ISO-TP, positive response 62 + DID) so it can replay through the same path.
Map<String, String> probe3Responses() {
  final text = File('captures/bmw_sme_2026-11-08.txt').readAsStringSync();
  final section = text.substring(text.indexOf('##### bmw_sme_probe3_'));
  final out = <String, String>{};
  final re = RegExp(r'^\s+(22[0-9A-F]{4})\s+-> (.*)$', multiLine: true);
  final decoded = RegExp(r'^[0-9a-f]{2}( [0-9a-f]{2})*$');
  for (final m in re.allMatches(section)) {
    final req = m.group(1)!;
    final body = m.group(2)!.trim();
    if (out.containsKey(req)) continue;
    if (decoded.hasMatch(body)) {
      final payload = body.split(' ').map((h) => int.parse(h, radix: 16));
      out[req] = _frame([0x62, ...hexBytes(req.substring(2)), ...payload]);
    } else if (body.startsWith('607')) {
      out[req] = '${body.replaceAll(' | ', '\r')}\r';
    }
  }
  return out;
}

List<int> hexBytes(String h) => [
      for (var i = 0; i < h.length; i += 2)
        int.parse(h.substring(i, i + 2), radix: 16)
    ];

/// UDS message -> ELM lines on 607 with BMW extended addressing.
String _frame(List<int> msg) {
  String line(List<int> b) =>
      '607 ${b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ')}';
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
  late Map<String, double> v;

  setUpAll(() async {
    set = SignalSet.parse(
        File('signalsets/BMW-330e-2018/v02.json').readAsStringSync());
    final source = ReplaySource(probe3Responses());
    await source.connect();
    final client = DiagnosticsClient(source, set);
    final failures = <CommandFailure>[];
    final all = await client.readAll(onFailure: failures.add);
    v = {for (final e in all.entries) e.key: e.value.value};
    // Only the J1979 PIDs (not in this capture) may fail.
    expect(failures.every((f) => f.command.service == '01'), isTrue,
        reason: failures.join('\n'));
  });

  test('SOC and window bounds (DDBC, incl. a 7F 22 78 pending frame)', () {
    expect(v['HVBAT_SOC'], closeTo(90.7, 1e-9));
    expect(v['HVBAT_SOC_WINDOW_MAX'], closeTo(78.0, 1e-9)); // BimmerLink: 78
    expect(v['HVBAT_SOC_WINDOW_MIN'], closeTo(24.6, 1e-9)); // BimmerLink: 25
  });

  test('SOH (6335, i3 layout)', () {
    expect(v['HVBAT_SOH'], 83);
  });

  test('pack voltage (DD66, from the DD00-DDFF sweep)', () {
    expect(v['HVBAT_VOLTAGE'], closeTo(315.83, 1e-9));
  });

  test('pack current (DD69): running and parked is a small DISCHARGE', () {
    // Raw FFFFFF6C = -1.48 A in the SME's own sign (+charge). The app's
    // convention is +discharge / -charge, so the signal set negates it.
    expect(v['HVBAT_CURRENT'], closeTo(1.48, 1e-9));
  });

  test('pack current while plug-in charging reads NEGATIVE (2026-11-13)',
      () async {
    // First sample of captures/bmw_chg_2026-11-13.txt, taken at ~3.2 kW AC
    // charging with displayed SOC rising: raw 0000044E = +11.02 A.
    final line = File('captures/bmw_chg_2026-11-13.txt')
        .readAsLinesSync()
        .firstWhere((l) => RegExp(r'^\d\d:\d\d:\d\d DD69=').hasMatch(l));
    final fields = {
      for (final f in line.split(' ').skip(1)) f.split('=')[0]: f.split('=')[1]
    };
    expect(fields['DD69'], '0000044e');
    final source = ReplaySource({
      for (final did in ['DD69', 'DD66', 'DDBC'])
        '22$did': _frame([0x62, ...hexBytes(did), ...hexBytes(fields[did]!)]),
    });
    await source.connect();
    final all = await DiagnosticsClient(source, set).readAll(onFailure: (_) {});
    expect(all['HVBAT_CURRENT']!.value, closeTo(-11.02, 1e-9));
    expect(all['HVBAT_VOLTAGE']!.value, closeTo(293.74, 1e-9));
    expect(all['HVBAT_SOC']!.value, closeTo(9.0, 1e-9));
  });

  test('cell temperatures (DDC0)', () {
    expect(v['HVBAT_CELLTEMP_MIN'], closeTo(15.99, 1e-9));
    expect(v['HVBAT_CELLTEMP_MAX'], closeTo(16.99, 1e-9));
    expect(v['HVBAT_CELLTEMP_AVG'], closeTo(16.21, 1e-9));
  });

  test('cell voltage and cell SoC (DFA0, 11-frame reply)', () {
    expect(v['HVBAT_CELL_V_MIN'], closeTo(3.9669, 1e-9));
    expect(v['HVBAT_CELL_V_MAX'], closeTo(3.9760, 1e-9));
    expect(v['HVBAT_CELL_V_AVG'], closeTo(3.9724, 1e-9));
    expect(v['HVBAT_CELL_SOC_MIN'], closeTo(71.44, 1e-9));
    expect(v['HVBAT_CELL_SOC_MAX'], closeTo(74.47, 1e-9));
    expect(v['HVBAT_CELL_SOC_AVG'], closeTo(73.42, 1e-9));
    expect(v['ODOMETER'], 77698); // BimmerLink: 48,281 mi = 77,701 km
  });
}
