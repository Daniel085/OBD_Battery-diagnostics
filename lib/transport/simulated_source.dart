/// Built-in demo/simulation [DataSource]s that answer ELM327 requests with
/// synthetic-but-plausible vehicle responses. They let the full app
/// (dashboard, report, capacity test, logging) run and be demoed without any
/// adapter or vehicle.
///
/// [SimulatedBmwSource] answers the BMW-330e-2018 signal set (11-bit,
/// extended addressing). [SimulatedLyriqSource] answers the
/// Cadillac-Lyriq-2025 set (29-bit `18DAxxF1` addressing) with the values
/// captured on the real car, and simulates an active 9 kW AC charge so the
/// capacity test demos end-to-end.
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

  /// Adapter state that matters for BMW framing (see elm327_protocol.dart).
  String _cea = ''; // ATCEA target address ('' = off)
  bool _customFc = false; // ATFCSM1
  String _fcData = '';
  bool _pendingNext = false; // alternate a 7F 22 78 in front, like the SME

  @override
  Future<String> send(String command, {Duration? timeout}) async {
    final cmd = command.trim().toUpperCase().replaceAll(' ', '');

    // AT setup commands: track the framing state, acknowledge everything.
    if (cmd.startsWith('AT')) {
      if (cmd.startsWith('ATCEA')) _cea = cmd.substring(5);
      if (cmd == 'ATFCSM1') _customFc = true;
      if (cmd == 'ATFCSM0') _customFc = false;
      if (cmd.startsWith('ATFCSD')) _fcData = cmd.substring(6);
      if (cmd == 'ATZ') {
        _cea = '';
        _customFc = false;
        _fcData = '';
      }
      return 'OK\r>';
    }

    // SME request: like the real car, answered only when the adapter inserts
    // the SME address (ATCEA07). The old malformed "0722<DID>" without it
    // (adapter PCI in front of the 07) gets NO DATA.
    if (_cea == '07') {
      if (cmd.length == 6 && cmd.startsWith('22')) {
        final resp = _responseForDid(cmd.substring(2, 6));
        if (resp != null) {
          _pendingNext = !_pendingNext;
          return _pendingNext ? '607 F1 03 7F 22 78 FF FF FF\r$resp' : resp;
        }
        return '607 F1 03 7F 22 31 FF FF FF\r>'; // requestOutOfRange
      }
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

  /// Build a 607 response for a DID with the layouts the real F30 SME
  /// returned on 2026-11-08 (captures/bmw_sme_2026-11-08.txt), lightly
  /// drifted so the demo dashboard moves.
  String? _responseForDid(String did) {
    List<int> u16(int v) => [(v >> 8) & 0xFF, v & 0xFF];
    switch (did) {
      case '6335': // SOH byte at payload bix 24
        return _single([0x62, 0x63, 0x35, 0x00, 0x00, 0x00, 83]);
      case 'DDBC': // SOC, window max, window min: u16 /10
        return _single([0x62, 0xDD, 0xBC, ...u16(_drift(907, 3)),
          ...u16(780), ...u16(246)]);
      case 'DD66': // pack voltage u16 /100
        return _single([0x62, 0xDD, 0x66, ...u16(_drift(31583, 20))]);
      case 'DD69': // pack current s32 /100
        final u = _drift(-148, 40) & 0xFFFFFFFF;
        return _single([0x62, 0xDD, 0x69,
          (u >> 24) & 0xFF, (u >> 16) & 0xFF, (u >> 8) & 0xFF, u & 0xFF]);
      case 'DDC0': // cell temp min/max/avg s16 /100 + status byte
        final t = _drift(1599, 5);
        return _single([0x62, 0xDD, 0xC0, ...u16(t), ...u16(t + 100),
          ...u16(t + 22), 0x01]);
      case 'DFA0': // 62-byte record of [min,max,avg] triples + trailer
        final v = _drift(39669, 8);
        final soc = _drift(7144, 4);
        return _single([0x62, 0xDF, 0xA0,
          ...u16(2364), ...u16(2460), ...u16(2424),
          ...u16(v), ...u16(v + 91), ...u16(v + 55), // cell V /10000
          ...u16(1599), ...u16(1699), ...u16(1621),
          ...u16(14881), ...u16(18731), ...u16(16235),
          ...u16(soc), ...u16(soc + 303), ...u16(soc + 198), // cell SoC /100
          ...u16(39880), ...u16(39930), ...u16(39904),
          0x41, 0xE9, 0x3E, 0x32, 0xDF, 0xD5, 0x39, 0xAF, 0x61, 0x0A,
          0x00, 0x14, 0x03, 0x20, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
          0x00, 0x00, 0x00, 0x01, 0x2F, 0x82]);
      default:
        return null;
    }
  }

  int _drift(int base, int amp) => base + (_rng.nextInt(2 * amp + 1) - amp);

  /// Single frame on 607 with BMW extended addressing:
  /// "607 F1 <len> <bytes...> <pad>".
  String _single(List<int> message) {
    // The address byte costs one data byte: single frames carry at most 6.
    if (message.length > 6) return _multi(message);
    final bytes = _pad([0xF1, message.length, ...message]);
    return '607 ${_hex(bytes)}\r>';
  }

  /// Multi-frame on 607 with BMW extended addressing: First Frame
  /// `F1 1L LL <5 bytes>` then Consecutive Frames `F1 2N <6 bytes>`. Like a
  /// real ECU, it stops after the First Frame unless the adapter is set to
  /// send flow control carrying the SME address (`07 30 ..`).
  String _multi(List<int> message) {
    final len = message.length;
    final first = [0xF1, 0x10 | ((len >> 8) & 0x0F), len & 0xFF,
      ...message.take(5)];
    final lines = <String>['607 ${_hex(first)}'];
    if (!_customFc || _fcData != '07300000') {
      return '${lines.join('\r')}\r>';
    }
    final rest = message.skip(5).toList();
    var seq = 1;
    for (var i = 0; i < rest.length; i += 6) {
      final chunk = rest.skip(i).take(6).toList();
      lines.add('607 ${_hex(_pad([0xF1, 0x20 | (seq & 0x0F), ...chunk]))}');
      seq++;
    }
    return '${lines.join('\r')}\r>';
  }

  List<int> _pad(List<int> frame) =>
      [...frame, for (var i = frame.length; i < 8; i++) 0xFF];

  String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
}

/// Simulated 2025 Cadillac Lyriq mid-charge, answering the exact ECUs/DIDs the
/// real car answered (29-bit addressing, values from the 2026-08 captures).
/// The pack current holds a steady ~−22.75 A (9 kW AC), so starting a capacity
/// test in demo mode accumulates real-looking charge.
class SimulatedLyriqSource implements DataSource {
  bool _connected = false;
  final math.Random _rng = math.Random(7);

  /// Last ATSH header — selects which simulated ECU a `22` request reaches.
  String _hdr = '7DF';

  @override
  String get name => 'Simulated Cadillac Lyriq (demo)';

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect() async => _connected = true;

  @override
  Future<void> disconnect() async => _connected = false;

  @override
  Future<String> send(String command, {Duration? timeout}) async {
    final cmd = command.trim().toUpperCase();
    if (cmd.startsWith('ATSH')) {
      _hdr = cmd.substring(4);
      return 'OK\r>';
    }
    if (cmd.startsWith('AT')) return 'OK\r>';

    if (cmd.startsWith('22') && cmd.length >= 6) {
      final resp = _udsResponse(cmd.substring(2, 6));
      return resp ?? 'NO DATA\r>';
    }
    if (cmd.startsWith('01') && cmd.length >= 4) {
      final resp = _j1979Response(cmd.substring(2, 4));
      return resp ?? 'NO DATA\r>';
    }
    return 'NO DATA\r>';
  }

  /// The ECU that answers for the current transmit header, e.g.
  /// 18DA17F1 -> responses from 18DAF117.
  String get _ecu =>
      _hdr.length == 8 && _hdr.startsWith('18DA') ? _hdr.substring(4, 6) : '28';

  String? _udsResponse(String did) {
    final data = switch ((_ecu, did)) {
      // ECU 17 (Bolt-style powertrain analog): the crown jewels.
      ('17', '2414') => _s16(_chargeAmps()), // pack current, s16 /20
      ('17', '2429') => _u16(0x5806), // nominal pack V constant 352.09
      // ECU 40 (energy summary).
      ('40', '416C') => _u16(_drift(0x13F4, 6)), // module V ~51.1
      ('40', '416D') => _u16(_drift(0x13EF, 6)),
      ('40', '416E') => _u16(_drift(0x13F4, 6)),
      ('40', '4127') => _u16(0x0418), // constant 32.75 C setpoint, as on the car
      ('40', '4124') => _u16(_drift(0x0410, 8)),
      ('40', '40E5') => _u16(_drift(0x0366, 6)), // ~27.2 C
      ('40', '40E6') => _u16(_drift(0x0361, 6)),
      ('40', '434F') => [25 + 40 + _rng.nextInt(2)], // byte-40 C
      // Controller SOH register: 93 steady, as measured on the real car
      // (SOC-independent — see docs/lyriq-re-log.md).
      ('40', '451D') => [93],
      ('40', '4149') => _u16(0x0184), // EVSE pilot 38.8 A (9.3 kW)
      ('40', '448F') => [0x00, 0x1E, 0xFE, 0x52], // odometer (=19,720 mi)
      // ECU 1D: 12V rail /10.
      ('1D', '33E5') => [0x84 + _rng.nextInt(2)], // ~13.2 V
      // ECU 28 (chassis): parked while charging.
      ('28', '4A7A') => [0, 0, 0, 0], // wheel speeds
      ('28', '4C2F') => _s16(_rng.nextInt(9) - 4), // accel noise
      ('28', '4C30') => _s16(_rng.nextInt(9) - 4),
      ('28', '4C2D') => _s16(-31), // steering -3.1 deg
      _ => null,
    };
    if (data == null) return null;
    final payload = [
      0x62,
      int.parse(did.substring(0, 2), radix: 16),
      int.parse(did.substring(2, 4), radix: 16),
      ...data,
    ];
    return _frame(payload);
  }

  /// Steady 9 kW AC charge: −22.75 A ±0.3 as raw s16 ×20 (≈ 0xFE39).
  int _chargeAmps() => -455 + _rng.nextInt(13) - 6;

  String? _j1979Response(String pid) {
    final data = switch (pid) {
      '0D' => [0], // vehicle speed: parked
      '42' => [0x36, 0xB0], // 14.0 V (DC-DC active while charging)
      _ => null,
    };
    if (data == null) return null;
    return _frame(
        [0x41, int.parse(pid, radix: 16), ...data],
        ecu: '28');
  }

  /// Single-frame ISO-TP response line exactly as the real adapter returns it
  /// with ATH1+ATS0: 29-bit id + PCI length + payload, no spaces.
  String _frame(List<int> payload, {String? ecu}) {
    final bytes = [payload.length, ...payload];
    final hex = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join();
    return '18DAF1${ecu ?? _ecu}$hex\r>';
  }

  List<int> _u16(int v) => [(v >> 8) & 0xFF, v & 0xFF];
  List<int> _s16(int v) {
    final u = v & 0xFFFF;
    return [(u >> 8) & 0xFF, u & 0xFF];
  }

  int _drift(int base, int amp) => base + (_rng.nextInt(2 * amp + 1) - amp);
}
