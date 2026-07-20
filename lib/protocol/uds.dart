/// Minimal UDS (ISO 14229) + J1979 response handling — read services only.
///
/// This module operates on already-reassembled message bytes (ISO-TP framing is
/// handled separately in `isotp.dart`). It builds request messages and parses
/// positive/negative responses, exposing the *data payload* (bytes after the
/// service echo and echoed identifier) for the formula evaluator.
///
/// Read-only by design: only services 0x22 (ReadDataByIdentifier),
/// 0x19 (ReadDTCInformation), 0x01 (J1979 current data), and 0x10
/// (DiagnosticSessionControl, sometimes needed to unlock reads) are modelled.
library;

/// UDS negative response codes we care to name. Not exhaustive.
const Map<int, String> udsNrcNames = {
  0x10: 'generalReject',
  0x11: 'serviceNotSupported',
  0x12: 'subFunctionNotSupported',
  0x13: 'incorrectMessageLengthOrInvalidFormat',
  0x22: 'conditionsNotCorrect',
  0x31: 'requestOutOfRange',
  0x33: 'securityAccessDenied',
  0x35: 'invalidKey',
  0x78: 'requestCorrectlyReceived-ResponsePending',
  0x7F: 'serviceNotSupportedInActiveSession',
};

class UdsNegativeResponse implements Exception {
  final int requestedService;
  final int nrc;
  UdsNegativeResponse(this.requestedService, this.nrc);

  String get nrcName => udsNrcNames[nrc] ?? 'unknown(0x${nrc.toRadixString(16)})';

  /// Response-pending is a "keep waiting" signal, not a hard failure.
  bool get isPending => nrc == 0x78;

  @override
  String toString() =>
      'UdsNegativeResponse(service=0x${requestedService.toRadixString(16)}, '
      'nrc=0x${nrc.toRadixString(16)} $nrcName)';
}

class UdsResponse {
  /// Positive-response service id (request service | 0x40).
  final int service;

  /// The identifier echoed back after the service byte (e.g. the 2-byte DID for
  /// 0x22, the 1-byte PID for 0x01). Empty for services without an echo.
  final List<int> identifier;

  /// The data payload after the service byte and echoed identifier — this is
  /// what SignalFormat.decode consumes.
  final List<int> data;

  const UdsResponse({
    required this.service,
    required this.identifier,
    required this.data,
  });
}

/// Build a UDS/J1979 request message (pre-ISO-TP), e.g. [0x22, 0xDD, 0xBC].
List<int> buildRequest(int service, List<int> payload) => [service, ...payload];

/// Parse a reassembled response message.
///
/// [requestService] and [identifierLength] describe what was asked so we can
/// verify the echo and split off the data payload:
///  - UDS 0x22: identifierLength = 2 (the DID).
///  - J1979 0x01: identifierLength = 1 (the PID).
///  - 0x19 / 0x10: identifierLength = 1 (the sub-function).
///
/// Throws [UdsNegativeResponse] on a 0x7F negative response, or [FormatException]
/// if the message is malformed or the service echo doesn't match.
UdsResponse parseResponse(
  List<int> message, {
  required int requestService,
  required int identifierLength,
}) {
  if (message.isEmpty) {
    throw const FormatException('Empty UDS response');
  }

  // Negative response: 0x7F <requestedService> <NRC>.
  if (message[0] == 0x7F) {
    if (message.length < 3) {
      throw const FormatException('Truncated UDS negative response');
    }
    throw UdsNegativeResponse(message[1], message[2]);
  }

  final expectedPositive = (requestService + 0x40) & 0xFF;
  if (message[0] != expectedPositive) {
    throw FormatException(
      'Unexpected response service 0x${message[0].toRadixString(16)} '
      '(expected 0x${expectedPositive.toRadixString(16)} for request '
      '0x${requestService.toRadixString(16)})',
    );
  }

  if (message.length < 1 + identifierLength) {
    throw FormatException(
      'Response too short: need service + $identifierLength identifier '
      'byte(s), got ${message.length} byte(s)',
    );
  }

  final identifier = message.sublist(1, 1 + identifierLength);
  final data = message.sublist(1 + identifierLength);
  return UdsResponse(
    service: message[0],
    identifier: identifier,
    data: data,
  );
}
