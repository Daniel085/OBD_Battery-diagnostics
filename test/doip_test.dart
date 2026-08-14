import 'dart:async';
import 'dart:typed_data';

import 'package:obd_battery_diagnostics/protocol/doip.dart';
import 'package:obd_battery_diagnostics/transport/doip_source.dart';
import 'package:test/test.dart';

void main() {
  group('DoIP framing', () {
    test('encode/decode round-trips a diagnostic message', () {
      final frame = diagnosticMessage(0x0E00, 0x0607, [0x22, 0xDD, 0xBC]);
      final res = decodeOne(frame)!;
      expect(res.consumed, frame.length);
      expect(res.message.payloadType, DoipPayloadType.diagnosticMessage);
      final dm = parseDiagnosticMessage(res.message.payload);
      expect(dm.source, 0x0E00);
      expect(dm.target, 0x0607);
      expect(dm.uds, [0x22, 0xDD, 0xBC]);
    });

    test('header carries version, inverse, type and length', () {
      final f = DoipMessage(0x8001, Uint8List.fromList([1, 2, 3])).encode();
      expect(f[0], 0x02); // version
      expect(f[1], 0xFD); // ~version
      expect((f[2] << 8) | f[3], 0x8001);
      expect((f[4] << 24) | (f[5] << 16) | (f[6] << 8) | f[7], 3);
    });

    test('decodeOne returns null until a full frame is buffered', () {
      final full = diagnosticMessage(0x0E00, 0x0607, [0x62, 0xDD, 0xBC, 0x03]);
      // Feed one byte short.
      expect(decodeOne(full.sublist(0, full.length - 1)), isNull);
      expect(decodeOne(full), isNotNull);
    });

    test('rejects a bad version byte', () {
      final bad = Uint8List.fromList([0x01, 0x00, 0x80, 0x01, 0, 0, 0, 0]);
      expect(() => decodeOne(bad), throwsFormatException);
    });

    test('routing activation request + response parse', () {
      final req = routingActivationRequest(0x0E00);
      final rr = decodeOne(req)!;
      expect(rr.message.payloadType, DoipPayloadType.routingActivationRequest);
      // Build a success response: tester, gateway, code 0x10.
      final resp = DoipMessage(
        DoipPayloadType.routingActivationResponse,
        Uint8List.fromList([0x0E, 0x00, 0x00, 0x10, 0x10]),
      );
      final act = parseRoutingActivationResponse(resp.payload);
      expect(act.isSuccess, isTrue);
      expect(act.gatewayAddress, 0x0010);
    });
  });

  group('DoipSource over a fake gateway socket', () {
    test('connects (routing activation) and reads an SME DID', () async {
      final gw = _FakeGateway();
      final src = DoipSource(
        socket: gw,
        config: const DoipConfig(
            host: 'test', port: 6801, testerAddress: 0x0E00, gatewayTarget: 0x0010),
      );
      // Program the gateway: SME (0x0607) answers 22DDBC with 62 DDBC 03 20.
      gw.onDiagnostic = (source, target, uds) {
        if (target == 0x0607 && uds.length >= 3 && uds[0] == 0x22) {
          return (from: 0x0607, uds: [0x62, uds[1], uds[2], 0x03, 0x20]);
        }
        return null;
      };

      await src.connect();
      expect(src.isConnected, isTrue);

      final resp = await src.request(0x0607, [0x22, 0xDD, 0xBC]);
      expect(resp, [0x62, 0xDD, 0xBC, 0x03, 0x20]);

      await src.disconnect();
    });

    test('routing activation failure throws', () async {
      final gw = _FakeGateway(activationCode: 0x06); // missing authentication
      final src = DoipSource(socket: gw);
      expect(() => src.connect(), throwsA(isA<DoipException>()));
    });

    test('gateway NACK surfaces as DoipException', () async {
      final gw = _FakeGateway();
      final src = DoipSource(socket: gw);
      gw.nackNext = 0x06; // target unreachable
      await src.connect();
      expect(() => src.request(0x0607, [0x22, 0xDD, 0xBC]),
          throwsA(isA<DoipException>()));
      await src.disconnect();
    });
  });
}

/// A scriptable in-memory DoIP gateway: answers routing activation, then routes
/// diagnostic messages to a programmable handler (or NACKs).
class _FakeGateway implements DoipSocket {
  final int activationCode;
  int? nackNext;
  ({int from, List<int> uds})? Function(int source, int target, List<int> uds)?
      onDiagnostic;

  final StreamController<List<int>> _in = StreamController<List<int>>();
  final List<int> _buf = [];

  _FakeGateway({this.activationCode = 0x10});

  @override
  Future<void> connect(String host, int port, {Duration? timeout}) async {}

  @override
  Stream<List<int>> get inbound => _in.stream;

  @override
  void add(List<int> bytes) {
    _buf.addAll(bytes);
    while (true) {
      final res = decodeOne(_buf);
      if (res == null) break;
      _buf.removeRange(0, res.consumed);
      _handle(res.message);
    }
  }

  void _handle(DoipMessage m) {
    if (m.payloadType == DoipPayloadType.routingActivationRequest) {
      final tester = (m.payload[0] << 8) | m.payload[1];
      _emit(DoipMessage(
        DoipPayloadType.routingActivationResponse,
        Uint8List.fromList([
          (tester >> 8) & 0xFF, tester & 0xFF, 0x00, 0x10, activationCode,
        ]),
      ));
    } else if (m.payloadType == DoipPayloadType.diagnosticMessage) {
      final dm = parseDiagnosticMessage(m.payload);
      if (nackNext != null) {
        final code = nackNext!;
        nackNext = null;
        _emit(DoipMessage(
          DoipPayloadType.diagnosticNegativeAck,
          Uint8List.fromList([
            (dm.target >> 8) & 0xFF, dm.target & 0xFF,
            (dm.source >> 8) & 0xFF, dm.source & 0xFF, code,
          ]),
        ));
        return;
      }
      // positive ack
      _emit(DoipMessage(DoipPayloadType.diagnosticPositiveAck,
          Uint8List.fromList([0, 0, 0, 0, 0x00])));
      final answer = onDiagnostic?.call(dm.source, dm.target, dm.uds);
      if (answer != null) {
        _emit(diagnosticMessageRaw(answer.from, dm.source, answer.uds));
      }
    }
  }

  void _emit(Object frameOrMsg) {
    final bytes = frameOrMsg is DoipMessage
        ? frameOrMsg.encode()
        : frameOrMsg as Uint8List;
    scheduleMicrotask(() {
      if (!_in.isClosed) _in.add(bytes);
    });
  }

  @override
  Future<void> close() async {
    if (!_in.isClosed) await _in.close();
  }
}

/// Helper: raw diagnostic-message frame (source→target) carrying [uds].
Uint8List diagnosticMessageRaw(int source, int target, List<int> uds) =>
    diagnosticMessage(source, target, uds);
