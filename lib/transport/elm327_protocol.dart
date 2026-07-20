/// ELM327 line-protocol helpers — pure string/byte logic, no I/O.
///
/// An ELM327 (and STN clones) speak an ASCII line protocol: you write an AT
/// command or a hex request terminated by CR, and read back ASCII text
/// terminated by the `>` prompt. This module builds command strings and parses
/// response text into raw CAN data fields, so the conversation logic can be
/// unit-tested against captured strings without a serial/BLE socket.
library;

/// The prompt character the ELM327 emits when ready for the next command.
const String elmPrompt = '>';

/// Canonical initialisation sequence for diagnostics. Order matters.
///   ATZ     reset            ATE0  echo off        ATL0  linefeeds off
///   ATS0    spaces off       ATH1  headers on (needed to see CAN ids)
///   ATSP<n> set protocol     ATAT1 adaptive timing
List<String> initCommands({required int obdProtocol}) => [
      'ATZ',
      'ATE0',
      'ATL0',
      'ATS0',
      'ATH1',
      'ATSP$obdProtocol',
      'ATAT1',
    ];

/// Set the transmit (tester) header, e.g. hdr "6F1" -> "AT SH 6F1".
String setHeaderCommand(String hdr) => 'ATSH$hdr';

/// Restrict received frames to a response id, e.g. rax "607" -> "AT CRA 607".
String setReceiveFilterCommand(String rax) => 'ATCRA$rax';

/// Clear any receive-address filter.
const String clearReceiveFilterCommand = 'ATCRA';

/// Build the hex request line for a UDS/J1979 message.
///
/// [messageBytes] is the service+payload (e.g. [0x22,0xDD,0xBC]). For BMW
/// extended tester addressing, [extendedAddress] (e.g. 0x07) is prepended as
/// the target-address byte the SME expects.
String requestLine(List<int> messageBytes, {int? extendedAddress}) {
  final bytes = <int>[
    if (extendedAddress != null) extendedAddress,
    ...messageBytes,
  ];
  return bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join();
}

/// Errors/adapter states surfaced as text rather than hex.
const Set<String> elmErrorTokens = {
  'NO DATA',
  'CAN ERROR',
  'BUS INIT',
  'BUS INIT: ERROR',
  'BUS BUSY',
  'BUS ERROR',
  'UNABLE TO CONNECT',
  'STOPPED',
  'ERROR',
  '?',
  'BUFFER FULL',
  'FB ERROR',
  'DATA ERROR',
  'ACT ALERT',
  'LP ALERT',
};

class ElmException implements Exception {
  final String token;
  ElmException(this.token);
  @override
  String toString() => 'ElmException($token)';
}

/// One decoded CAN frame from an ELM327 response line (headers on).
class ElmFrame {
  /// CAN id as parsed from the leading header field (hex string, no spaces).
  final String canId;

  /// The data field bytes (the ISO-TP frame payload).
  final List<int> data;

  const ElmFrame({required this.canId, required this.data});
}

/// Parse the raw text the ELM327 returned for a single request into CAN frames.
///
/// With headers on (ATH1) and spaces off (ATS0), each response line looks like
/// a run of hex nibbles beginning with the CAN id. Header width depends on
/// addressing: 11-bit ids are 3 hex chars, 29-bit ids are 8 hex chars.
/// Multi-frame ISO-TP responses arrive as several lines (the adapter having
/// done flow control). Whitespace/prompt are tolerated; error tokens throw.
List<ElmFrame> parseFrames(
  String raw, {
  required bool is29Bit,
}) {
  final headerNibbles = is29Bit ? 8 : 3;
  final frames = <ElmFrame>[];
  for (var line in raw.split(RegExp(r'[\r\n]+'))) {
    line = line.replaceAll(elmPrompt, '').trim();
    if (line.isEmpty) continue;

    final upper = line.toUpperCase();
    for (final tok in elmErrorTokens) {
      if (upper == tok || upper.startsWith('$tok ')) {
        throw ElmException(tok);
      }
    }

    // Keep only hex chars (some adapters still slip in stray spaces).
    final hex = upper.replaceAll(RegExp(r'[^0-9A-F]'), '');
    if (hex.length <= headerNibbles) continue; // header only, no data

    final canId = hex.substring(0, headerNibbles);
    final dataHex = hex.substring(headerNibbles);
    if (dataHex.length.isOdd) continue; // malformed data, skip defensively
    final data = <int>[];
    for (var i = 0; i < dataHex.length; i += 2) {
      data.add(int.parse(dataHex.substring(i, i + 2), radix: 16));
    }
    frames.add(ElmFrame(canId: canId, data: data));
  }
  return frames;
}
