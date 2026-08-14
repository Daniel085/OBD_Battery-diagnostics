import 'dart:async';
import 'dart:typed_data';

import 'package:obd_battery_diagnostics/engine/signal_set.dart';
import 'package:obd_battery_diagnostics/engine/uds_diagnostics_client.dart';
import 'package:obd_battery_diagnostics/transport/uds_transport.dart';
import 'package:test/test.dart';

/// A fake UdsTransport that returns scripted UDS responses per target — proves
/// the signal-set decode path works over a DoIP-style transport (no ISO-TP /
/// AT handling), which is what unlocks the gateway-routed SME on the BMW.
class _FakeUds implements UdsTransport {
  final Map<int, Uint8List> byTarget;
  bool _c = false;
  _FakeUds(this.byTarget);
  @override
  String get name => 'fake';
  @override
  bool get isConnected => _c;
  @override
  Future<void> connect() async => _c = true;
  @override
  Future<void> disconnect() async => _c = false;
  @override
  Future<Uint8List> request(int target, List<int> uds, {Duration? timeout}) async {
    final r = byTarget[target];
    if (r == null) throw StateError('no scripted response for 0x${target.toRadixString(16)}');
    return r;
  }
}

void main() {
  test('reads BMW SME SOC over a UdsTransport end-to-end', () async {
    // Minimal SME signal set: SOC via 22 DDBC on ECU response 0x607.
    final set = SignalSet.parse('''
    {
      "vehicle":"BMW-SME-doip",
      "protocol":{"canFormat":"11bit"},
      "commands":[{
        "hdr":"6F1","rax":"607","cmd":{"22":"DDBC"},
        "signals":[{"id":"HVBAT_SOC","name":"SOC","group":"summary",
          "fmt":{"bix":0,"len":16,"div":10,"unit":"percent"}}]
      }]
    }''');

    // SME (0x0607) answers with 62 DDBC 03 20 -> raw 0x0320 = 800 -> /10 = 80%.
    final transport = _FakeUds({
      0x607: Uint8List.fromList([0x62, 0xDD, 0xBC, 0x03, 0x20]),
    });
    await transport.connect();

    final client = UdsDiagnosticsClient(transport, set);
    final all = await client.readAll();

    expect(all['HVBAT_SOC']!.value, closeTo(80.0, 1e-9));
    expect(all['HVBAT_SOC']!.unit, 'percent');
  });
}
