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

// ---------------------------------------------------------------------------
// BMW extended addressing (ISO 15765-2 "extended" format)
// ---------------------------------------------------------------------------
//
// Every BMW F/G-series ECU behind the ZGW gateway is addressed this way. The
// FIRST data byte of each CAN frame is an address byte, and the ISO-TP PCI
// comes AFTER it:
//
//   request  on 6F1:  <target> <PCI> <SID> <payload..>   07 03 22 DD BC
//   response on 6xx:  <F1>     <PCI> <SID+40> <data..>   F1 10 09 62 DD BC ..
//   flow control 6F1: <target> 30 00 00
//
// Prepending "07" to a request line while the adapter auto-formats puts the
// adapter's PCI first (`04 07 22 DD BC`), a frame no BMW ECU answers. That is
// what the app sent in Aug 2026, which made the SME look unreachable.
//
// Recipe proven on the 330e with the Viecar ELM327 v2.2 clone (2026-11-08,
// tools/bmw-sme-probe, captures/bmw_sme_2026-11-08.txt):
//   * ATCEA<target> makes the adapter insert the address byte on requests;
//   * the adapter's own flow control does NOT carry the address, so we set a
//     custom FC frame `<target> 30 00 00` (FCSM1). Without it only the First
//     Frame of a multi-frame reply arrives;
//   * the SME often answers `7F 22 78` (response pending) first, so adaptive
//     timing is off and the timeout is maxed (ATSTFF, ~1 s per wait). That
//     wait follows EVERY reply, so one request takes ~1.25 s (0.8 Hz). Drive
//     mode shortens it through DiagnosticsClient.fastTiming, which falls back
//     to this default by itself if a reply is missed.
// Responses are still displayed with the leading F1 (strip it before ISO-TP).

/// AT commands that switch the adapter into BMW extended addressing for
/// [target] (e.g. 0x07 = SME) using tester header [hdr] (e.g. "6F1").
List<String> extendedAddressingCommands({
  required String hdr,
  required int target,
}) =>
    [
      'ATCAF1',
      'ATCEA${_hex2(target)}', // adapter inserts the target byte on requests
      'ATFCSH$hdr', // flow control is sent from the tester id
      'ATFCSD${_hex2(target)}300000', // FC frame: <target> 30 00 00
      'ATFCSM1', // use the user-defined FC header + data
      'ATAT0', // the SME is slow (7F xx 78): no adaptive shortening
      'ATSTFF', // max response timeout
    ];

/// AT commands that restore normal ISO-TP addressing and default timing.
const List<String> normalAddressingCommands = [
  'ATCEA',
  'ATFCSM0',
  'ATAT1',
  'ATST32',
];

/// Build the hex request line for a UDS/J1979 message, e.g. [0x22,0xDD,0xBC]
/// -> "22DDBC". The adapter adds the PCI (and, in extended mode, the address
/// byte).
String requestLine(List<int> messageBytes) => messageBytes.map(_hex2).join();

/// Strip the leading address byte from a frame received under extended
/// addressing (`F1 05 62 ...` -> `05 62 ...`) so ISO-TP reassembly sees the PCI
/// first, exactly as with normal addressing.
List<int> stripExtendedAddress(List<int> data) {
  if (data.length < 2) {
    throw const FormatException('Extended-addressing frame too short');
  }
  return data.sublist(1);
}

/// True for a single-frame UDS "response pending" (`03 7F <sid> 78`). A slow
/// ECU sends it before the real answer; it is not the answer, so drop it before
/// reassembly.
bool isResponsePending(List<int> dataField) =>
    dataField.length >= 4 &&
    dataField[0] == 0x03 &&
    dataField[1] == 0x7F &&
    dataField[3] == 0x78;

/// Turn the CAN frames of one response into ISO-TP data fields: strip the
/// address byte under extended addressing and drop response-pending frames.
List<List<int>> responseDataFields(List<ElmFrame> frames,
        {required bool extendedAddressing}) =>
    frames
        .map((f) =>
            extendedAddressing ? stripExtendedAddress(f.data) : f.data)
        .where((d) => !isResponsePending(d))
        .toList();

String _hex2(int b) => b.toRadixString(16).padLeft(2, '0').toUpperCase();

/// An adapter reply as one line of text: its lines joined by " | ", the
/// prompt dropped. The form captures and reports are written in.
String replyOnOneLine(String raw) => raw
    .split(RegExp(r'[\r\n]+'))
    .map((l) => l.replaceAll(elmPrompt, '').trim())
    .where((l) => l.isNotEmpty)
    .join(' | ');

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
