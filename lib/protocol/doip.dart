/// DoIP (Diagnostics over IP, ISO 13400) message framing.
///
/// This is the protocol BMW's ENET cable + ISTA use: UDS diagnostic messages
/// wrapped in a small Ethernet/TCP header and routed by the vehicle gateway
/// (ZGW) to the target ECU — including ECUs (like the SME battery module) that
/// the gateway does *not* bridge onto the OBD-II CAN pins. Reaching those is the
/// whole point of this transport.
///
/// Pure byte logic here (no sockets) so it is fully unit-testable. The TCP
/// transport that carries these frames lives in `lib/transport/doip_source.dart`.
library;

import 'dart:typed_data';

/// DoIP protocol version. 0x02 = ISO 13400-2:2012, used by BMW ENET.
const int doipVersion = 0x02;

/// Header: version, ~version, 2-byte payload type, 4-byte payload length.
const int doipHeaderLength = 8;

/// Payload types we use (ISO 13400-2).
class DoipPayloadType {
  static const int routingActivationRequest = 0x0005;
  static const int routingActivationResponse = 0x0006;
  static const int aliveCheckRequest = 0x0007;
  static const int aliveCheckResponse = 0x0008;

  /// Diagnostic message: [sourceAddr(2)][targetAddr(2)][UDS bytes...].
  static const int diagnosticMessage = 0x8001;

  /// Positive ack that the gateway accepted a diagnostic message.
  static const int diagnosticPositiveAck = 0x8002;

  /// Negative ack (gateway could not route / target unreachable).
  static const int diagnosticNegativeAck = 0x8003;
}

/// Routing-activation response codes (ISO 13400-2, table 48). 0x10 = success.
const Map<int, String> routingActivationCodes = {
  0x00: 'unknown source address',
  0x02: 'all sockets registered/active',
  0x03: 'SA different from activated one',
  0x04: 'SA already registered/active',
  0x06: 'missing authentication',
  0x07: 'rejected confirmation',
  0x10: 'success',
  0x11: 'requires confirmation',
};

/// Negative-ack codes for a diagnostic message (ISO 13400-2, table 51).
const Map<int, String> diagnosticNackCodes = {
  0x02: 'invalid source address',
  0x03: 'unknown target address',
  0x04: 'diagnostic message too large',
  0x05: 'out of memory',
  0x06: 'target unreachable',
  0x07: 'unknown network',
  0x08: 'transport protocol error',
};

class DoipMessage {
  final int payloadType;
  final Uint8List payload;
  const DoipMessage(this.payloadType, this.payload);

  /// Serialize to the full 8-byte-header + payload wire form.
  Uint8List encode() {
    final out = Uint8List(doipHeaderLength + payload.length);
    out[0] = doipVersion;
    out[1] = (~doipVersion) & 0xFF;
    out[2] = (payloadType >> 8) & 0xFF;
    out[3] = payloadType & 0xFF;
    final len = payload.length;
    out[4] = (len >> 24) & 0xFF;
    out[5] = (len >> 16) & 0xFF;
    out[6] = (len >> 8) & 0xFF;
    out[7] = len & 0xFF;
    out.setRange(doipHeaderLength, out.length, payload);
    return out;
  }
}

/// Parse exactly one DoIP message from the front of [buf].
///
/// Returns the message plus the number of bytes consumed, or null if [buf]
/// doesn't yet hold a complete frame (caller should read more from the socket).
/// Throws [FormatException] on a malformed header.
({DoipMessage message, int consumed})? decodeOne(List<int> buf) {
  if (buf.length < doipHeaderLength) return null;
  if (buf[0] != doipVersion || buf[1] != ((~doipVersion) & 0xFF)) {
    throw FormatException(
        'Bad DoIP version bytes ${buf[0].toRadixString(16)}/'
        '${buf[1].toRadixString(16)}');
  }
  final payloadType = (buf[2] << 8) | buf[3];
  final len = (buf[4] << 24) | (buf[5] << 16) | (buf[6] << 8) | buf[7];
  if (buf.length < doipHeaderLength + len) return null; // wait for more
  final payload =
      Uint8List.fromList(buf.sublist(doipHeaderLength, doipHeaderLength + len));
  return (
    message: DoipMessage(payloadType, payload),
    consumed: doipHeaderLength + len,
  );
}

/// Build a routing-activation request. [sourceAddress] is the tester's logical
/// address (BMW ISTA uses 0x0E00 / 0x0EF1-range). activationType 0x00 = default.
Uint8List routingActivationRequest(int sourceAddress,
    {int activationType = 0x00}) {
  // [SA(2)][activationType(1)][reserved(4, 0)].
  final p = Uint8List(7);
  p[0] = (sourceAddress >> 8) & 0xFF;
  p[1] = sourceAddress & 0xFF;
  p[2] = activationType;
  // bytes 3..6 reserved = 0
  return DoipMessage(DoipPayloadType.routingActivationRequest, p).encode();
}

class RoutingActivationResult {
  final int testerAddress;
  final int gatewayAddress;
  final int responseCode;
  const RoutingActivationResult(
      this.testerAddress, this.gatewayAddress, this.responseCode);
  bool get isSuccess => responseCode == 0x10;
  String get codeName =>
      routingActivationCodes[responseCode] ??
      'code 0x${responseCode.toRadixString(16)}';
}

RoutingActivationResult parseRoutingActivationResponse(Uint8List payload) {
  if (payload.length < 5) {
    throw const FormatException('Short routing-activation response');
  }
  final tester = (payload[0] << 8) | payload[1];
  final gateway = (payload[2] << 8) | payload[3];
  final code = payload[4];
  return RoutingActivationResult(tester, gateway, code);
}

/// Wrap UDS bytes in a DoIP diagnostic message addressed [source]→[target].
Uint8List diagnosticMessage(int source, int target, List<int> uds) {
  final p = Uint8List(4 + uds.length);
  p[0] = (source >> 8) & 0xFF;
  p[1] = source & 0xFF;
  p[2] = (target >> 8) & 0xFF;
  p[3] = target & 0xFF;
  p.setRange(4, p.length, uds);
  return DoipMessage(DoipPayloadType.diagnosticMessage, p).encode();
}

class DiagnosticMessagePayload {
  final int source;
  final int target;
  final Uint8List uds;
  const DiagnosticMessagePayload(this.source, this.target, this.uds);
}

/// Split a received diagnostic-message payload into addresses + UDS bytes.
DiagnosticMessagePayload parseDiagnosticMessage(Uint8List payload) {
  if (payload.length < 4) {
    throw const FormatException('Short DoIP diagnostic message');
  }
  final source = (payload[0] << 8) | payload[1];
  final target = (payload[2] << 8) | payload[3];
  return DiagnosticMessagePayload(
      source, target, Uint8List.fromList(payload.sublist(4)));
}
