/// A transport that exchanges *complete UDS messages* with a target ECU.
///
/// This is the seam that lets one diagnostics engine drive very different
/// physical links:
///  - `ElmUdsTransport` — wraps an ELM327 (AT commands + ISO-TP reassembly).
///  - `DoipSource`       — DoIP over TCP (BMW ENET), reaching gateway-routed
///                         ECUs the OBD-II CAN pins never expose.
///
/// The engine hands over a target address + UDS request bytes (e.g.
/// `[0x22, 0xDD, 0xBC]`) and gets back the reassembled UDS response bytes
/// (e.g. `[0x62, 0xDD, 0xBC, ...]`), with ISO-TP / DoIP framing already handled.
library;

import 'dart:typed_data';

abstract interface class UdsTransport {
  /// Human-readable identity (for logs/UI).
  String get name;

  bool get isConnected;

  /// Establish the link (open socket, do the DoIP routing-activation handshake,
  /// or run the ELM327 init sequence).
  Future<void> connect();

  /// Send a UDS request to [target] and return the reassembled response bytes.
  ///
  /// [target] is the ECU's logical/diagnostic address (e.g. BMW `0x0607` for
  /// the SME response, or the CAN header the ELM transport should use).
  /// Throws on transport failure; a UDS *negative* response is returned as-is
  /// for the caller (uds.dart) to interpret.
  Future<Uint8List> request(int target, List<int> uds, {Duration? timeout});

  Future<void> disconnect();
}
