/// A built-in demo/simulation [DataSource] that answers ELM327 requests with
/// synthetic-but-plausible BMW 330e SME responses. Lets the full app (dashboard,
/// report, logging) run and be demoed without any adapter or vehicle.
///
/// It understands just enough of the ELM327 line protocol for the BMW-330e-2018
/// signal set: it recognises the request line (extended addr 07 + 22 + DID) and
/// replies with a single- or multi-frame 607 response carrying values that
/// drift slightly over time so the dashboard looks alive.
library;

import 'dart:math' as math;

import 'data_source.dart';

class SimulatedBmwSource implements DataSource {
  bool _connected = false;
  final math.Random _rng = math.Random(42);

  @override
  String get name => 'Simulated BMW 330e (demo)';

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect() async => _connected = true;

  @override
  Future<void> disconnect() async => _connected = false;

  @override
  Future<String> send(String command, {Duration? timeout}) async {
    final cmd = command.trim().toUpperCase();

    // AT setup commands: acknowledge.
    if (cmd.startsWith('AT')) return 'OK\r>';

    // Request lines look like "0722<DID>" (extended addr 07 + service 22 + DID).
    if (cmd.startsWith('0722') && cmd.length >= 8) {
      final did = cmd.substring(4, 8);
      final resp = _responseForDid(did);
      if (resp != null) return resp;
      return 'NO DATA\r>';
    }
    // Standard J1979 mode-01 PIDs (what the real 330e answers on 7Ex).
    if (cmd.startsWith('01') && cmd.length >= 4) {
      final resp = _responseForPid(cmd.substring(2, 4));
      if (resp != null) return resp;
      return 'NO DATA\r>';
    }
    return 'NO DATA\r>';
  }

  /// Standard J1979 mode-01 responses on 7E8, matching what the 330e returns.
  String? _responseForPid(String pid) {
    int? b0, b1;
    switch (pid) {
      case '5B': // HV battery charge, x100/255 %
        b0 = 195 + _rng.nextInt(8); // ~78%
      case '5C': // oil temp, raw-40
        b0 = 90 + _rng.nextInt(3); // ~51C
      case '46': // ambient temp, raw-40
        b0 = 65;
      case '2F': // fuel level, x100/255
        b0 = 128;
      case '42': // control module voltage, /1000 (2 bytes)
        b0 = 0x36;
        b1 = 0xD8;
    }
    if (b0 == null) return null;
    // SOC (5B) answers from 7EB on the real car; others from 7E8.
    final respId = pid == '5B' ? '7EB' : '7E8';
    final bytes = [0x41, int.parse(pid, radix: 16), b0, if (b1 != null) b1];
    return '$respId ${_hex([bytes.length, ...bytes])}\r>';
  }

  /// Build a 607 response for a DID, framed as ISO-TP over the ELM line format.
  String? _responseForDid(String did) {
    switch (did) {
      case '6335': // SOH, 8-bit at bix 24 -> need 3 leading bytes then value
        // 62 63 35 <3 pad bytes> <SOH>  → SOH byte at payload bix 24
        final soh = 92 + _rng.nextInt(2); // 92-93 %
        return _single([0x62, 0x63, 0x35, 0x00, 0x00, 0x00, soh]);
      case 'DDBC': // SOC 16-bit /10
        final soc = _drift(615, 3); // ~61.5 %
        return _single([0x62, 0xDD, 0xBC, (soc >> 8) & 0xFF, soc & 0xFF]);
      case 'DD68': // pack voltage 16-bit /100
        final v = _drift(35010, 40); // ~350.1 V
        return _single([0x62, 0xDD, 0x68, (v >> 8) & 0xFF, v & 0xFF]);
      case 'DD69': // pack current 32-bit signed /100
        final c = _drift(-250, 120); // ~ -2.5 A (mild discharge), signed
        final u = c & 0xFFFFFFFF;
        return _single([
          0x62, 0xDD, 0x69,
          (u >> 24) & 0xFF, (u >> 16) & 0xFF, (u >> 8) & 0xFF, u & 0xFF,
        ]);
      case 'DDC0': // cell temp min/max, two 16-bit /100 signed
        final tmin = _drift(2180, 30); // 21.8 C
        final tmax = _drift(2450, 30); // 24.5 C
        return _multi([
          0x62, 0xDD, 0xC0,
          (tmin >> 8) & 0xFF, tmin & 0xFF,
          (tmax >> 8) & 0xFF, tmax & 0xFF,
        ]);
      case 'DFA0': // cell voltage min/max/avg, three 16-bit /10000
        final vmin = _drift(38400, 40); // 3.8400 V
        final vmax = vmin + 60 + _rng.nextInt(20); // small spread ~6-8 mV
        final vavg = (vmin + vmax) ~/ 2;
        return _multi([
          0x62, 0xDF, 0xA0,
          (vmin >> 8) & 0xFF, vmin & 0xFF,
          (vmax >> 8) & 0xFF, vmax & 0xFF,
          (vavg >> 8) & 0xFF, vavg & 0xFF,
        ]);
      default:
        return null;
    }
  }

  int _drift(int base, int amp) => base + (_rng.nextInt(2 * amp + 1) - amp);

  /// Single-frame ISO-TP line: "607 <len> <bytes...>".
  String _single(List<int> message) {
    final bytes = [message.length, ...message];
    return '607 ${_hex(bytes)}\r>';
  }

  /// Multi-frame ISO-TP: First Frame + Consecutive Frames on 607.
  String _multi(List<int> message) {
    final len = message.length;
    final first = [0x10, len, ...message.take(6)];
    final rest = message.skip(6).toList();
    final lines = <String>['607 ${_hex(first)}'];
    var seq = 1;
    for (var i = 0; i < rest.length; i += 7) {
      final chunk = rest.skip(i).take(7).toList();
      final cf = [0x20 | (seq & 0x0F), ...chunk];
      lines.add('607 ${_hex(cf)}');
      seq++;
    }
    return '${lines.join('\r')}\r>';
  }

  String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
}
