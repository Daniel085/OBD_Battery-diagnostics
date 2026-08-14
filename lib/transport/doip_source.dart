/// DoIP transport (BMW ENET). Connects to the vehicle gateway over TCP, performs
/// routing activation, then exchanges UDS via DoIP diagnostic messages — the
/// path that reaches gateway-routed ECUs (e.g. the SME battery module) which the
/// OBD-II CAN pins never expose.
///
/// The raw byte socket is abstracted as [DoipSocket] so the DoIP logic (framing,
/// routing activation, response demux) is unit-tested with a fake, and the real
/// `dart:io` TCP socket is a thin adapter.
library;

import 'dart:async';
import 'dart:typed_data';

import '../protocol/doip.dart';
import 'uds_transport.dart';

/// Minimal byte-stream socket the DoIP transport drives.
abstract interface class DoipSocket {
  Future<void> connect(String host, int port, {Duration? timeout});
  void add(List<int> bytes);

  /// Inbound bytes from the gateway (may be chunked arbitrarily by TCP).
  Stream<List<int>> get inbound;
  Future<void> close();
}

/// BMW ENET defaults. With an ENET cable the gateway (ZGW) presents itself on a
/// link-local address; ISTA's tester logical address is in the 0x0Exx range.
class DoipConfig {
  final String host;
  final int port;
  final int testerAddress; // our (tester) logical source address
  final int gatewayTarget; // logical address to route through (gateway/functional)
  final Duration responseTimeout;

  const DoipConfig({
    this.host = '169.254.255.255',
    this.port = 6801, // ISO 13400 DoIP TCP data port is 13400; BMW ENET commonly 6801
    this.testerAddress = 0x0E00,
    this.gatewayTarget = 0x0010,
    this.responseTimeout = const Duration(seconds: 5),
  });

  /// Standard ISO 13400 DoIP (port 13400) — for non-BMW / generic gateways.
  factory DoipConfig.standard({String host = '192.168.0.10'}) => DoipConfig(
        host: host,
        port: 13400,
        testerAddress: 0x0E80,
        gatewayTarget: 0x1000,
      );
}

class DoipException implements Exception {
  final String message;
  DoipException(this.message);
  @override
  String toString() => 'DoipException($message)';
}

class DoipSource implements UdsTransport {
  final DoipSocket socket;
  final DoipConfig config;

  final List<int> _rx = [];
  final StreamController<DoipMessage> _messages =
      StreamController<DoipMessage>.broadcast();
  // A queue + waiter so no inbound DoIP message is lost between reads (a plain
  // broadcast `.first` in a loop would drop frames that arrive between awaits).
  final List<DoipMessage> _queue = [];
  Completer<DoipMessage>? _waiter;
  StreamSubscription<List<int>>? _sub;
  bool _connected = false;

  DoipSource({required this.socket, DoipConfig? config})
      : config = config ?? const DoipConfig();

  @override
  String get name => 'DoIP ${config.host}:${config.port}';

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect() async {
    await socket.connect(config.host, config.port,
        timeout: config.responseTimeout);
    _sub = socket.inbound.listen(_onBytes, onError: (Object e) {
      if (!_messages.isClosed) _messages.addError(e);
    });

    // Routing activation — the gateway won't route diagnostics until this
    // succeeds.
    socket.add(routingActivationRequest(config.testerAddress));
    final resp = await _nextOfType(
      DoipPayloadType.routingActivationResponse,
      config.responseTimeout,
    );
    final act = parseRoutingActivationResponse(resp.payload);
    if (!act.isSuccess) {
      throw DoipException('Routing activation failed: ${act.codeName}');
    }
    _connected = true;
  }

  void _onBytes(List<int> bytes) {
    _rx.addAll(bytes);
    // Drain as many complete DoIP frames as are buffered.
    while (true) {
      final res = decodeOne(_rx);
      if (res == null) break;
      _rx.removeRange(0, res.consumed);
      _deliver(res.message);
    }
  }

  void _deliver(DoipMessage m) {
    if (!_messages.isClosed) _messages.add(m); // for external observers
    final w = _waiter;
    if (w != null && !w.isCompleted) {
      _waiter = null;
      w.complete(m);
    } else {
      _queue.add(m);
    }
  }

  /// Next inbound DoIP message (from the queue, or awaited), never dropped.
  Future<DoipMessage> _next(Duration timeout) {
    if (_queue.isNotEmpty) return Future.value(_queue.removeAt(0));
    final c = Completer<DoipMessage>();
    _waiter = c;
    return c.future.timeout(timeout, onTimeout: () {
      _waiter = null;
      throw DoipException('Timed out waiting for DoIP message');
    });
  }

  Future<DoipMessage> _nextOfType(int payloadType, Duration timeout) async {
    final stop = Stopwatch()..start();
    while (stop.elapsed < timeout) {
      final m = await _next(timeout - stop.elapsed);
      if (m.payloadType == payloadType) return m;
    }
    throw DoipException(
        'Timed out waiting for DoIP 0x${payloadType.toRadixString(16)}');
  }

  @override
  Future<Uint8List> request(int target, List<int> uds,
      {Duration? timeout}) async {
    if (!_connected) throw DoipException('DoIP not connected');
    final to = timeout ?? config.responseTimeout;

    socket.add(diagnosticMessage(config.testerAddress, target, uds));

    // The gateway first acks (0x8002) or nacks (0x8003), then the ECU's actual
    // diagnostic response arrives as another 0x8001 from the target address.
    final stop = Stopwatch()..start();
    while (stop.elapsed < to) {
      final DoipMessage m;
      try {
        m = await _next(to - stop.elapsed);
      } on DoipException {
        break;
      }
      switch (m.payloadType) {
        case DoipPayloadType.diagnosticNegativeAck:
          final nack = m.payload.length > 4 ? m.payload[4] : -1;
          throw DoipException(
              'Gateway NACK: ${diagnosticNackCodes[nack] ?? 'code $nack'}');
        case DoipPayloadType.diagnosticPositiveAck:
          // Ack only — keep waiting for the ECU's real response.
          continue;
        case DoipPayloadType.diagnosticMessage:
          final dm = parseDiagnosticMessage(m.payload);
          // Accept the response coming *from* the target we addressed.
          if (dm.source == target || target == config.gatewayTarget) {
            return dm.uds;
          }
          continue;
        case DoipPayloadType.aliveCheckRequest:
          socket.add(DoipMessage(
            DoipPayloadType.aliveCheckResponse,
            Uint8List(2)
              ..[0] = (config.testerAddress >> 8) & 0xFF
              ..[1] = config.testerAddress & 0xFF,
          ).encode());
          continue;
        default:
          continue;
      }
    }
    throw DoipException('No diagnostic response from '
        '0x${target.toRadixString(16)}');
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    await _sub?.cancel();
    _sub = null;
    await socket.close();
    if (!_messages.isClosed) await _messages.close();
  }
}
