/// UDS DID scanner — discovery tool for vehicles whose battery DIDs are unknown
/// (e.g. the Cadillac Lyriq). Sweeps UDS service 0x22 across a range of Data
/// Identifiers on a target ECU and classifies each response.
///
/// The scan *logic* (which DIDs to try, how to classify a response) is pure and
/// testable. Actual bus I/O goes through a [DiagnosticsClient]'s [DataSource].
///
/// Still read-only: this only issues 0x22 reads. It never writes. A DID sweep
/// is generally safe, but is gated behind an explicit user action in the UI and
/// should be run with the vehicle stationary.
library;

import '../engine/signal_set.dart';
import '../protocol/isotp.dart';
import '../protocol/uds.dart';
import '../transport/data_source.dart';
import '../transport/elm327_protocol.dart';

enum DidStatus {
  /// Positive response — the DID exists and returned data.
  responded,

  /// Negative response 0x31 requestOutOfRange — DID not supported.
  outOfRange,

  /// Other negative response (e.g. security/session needed).
  negativeOther,

  /// No frames / adapter NO DATA — DID silent.
  noData,

  /// Malformed or unparseable response.
  malformed,
}

class DidScanResult {
  final int did;
  final DidStatus status;

  /// Raw data payload (after service+DID echo) when [status] is responded.
  final List<int>? data;

  /// NRC byte when a negative response.
  final int? nrc;

  const DidScanResult(this.did, this.status, {this.data, this.nrc});

  String get didHex => did.toRadixString(16).padLeft(4, '0').toUpperCase();

  bool get isInteresting => status == DidStatus.responded;

  @override
  String toString() {
    final base = 'DID $didHex: ${status.name}';
    if (status == DidStatus.responded && data != null) {
      final hex =
          data!.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
      return '$base [${data!.length} bytes: $hex]';
    }
    if (nrc != null) {
      return '$base (nrc 0x${nrc!.toRadixString(16)})';
    }
    return base;
  }
}

class UdsScanner {
  final DataSource source;

  /// Addressing for the target ECU.
  final String requestHeader; // e.g. "6F1" or a GM tester id
  final String? responseFilter; // e.g. "607"
  final int? extendedAddress; // e.g. 0x07
  final bool is29Bit;

  UdsScanner({
    required this.source,
    required this.requestHeader,
    this.responseFilter,
    this.extendedAddress,
    this.is29Bit = false,
  });

  /// Classify a single reassembled response message for request DID [did].
  static DidScanResult classify(int did, List<int>? message) {
    if (message == null || message.isEmpty) {
      return DidScanResult(did, DidStatus.noData);
    }
    try {
      final resp = parseResponse(message,
          requestService: 0x22, identifierLength: 2);
      return DidScanResult(did, DidStatus.responded, data: resp.data);
    } on UdsNegativeResponse catch (e) {
      return DidScanResult(
        did,
        e.nrc == 0x31 ? DidStatus.outOfRange : DidStatus.negativeOther,
        nrc: e.nrc,
      );
    } on FormatException {
      return DidScanResult(did, DidStatus.malformed);
    }
  }

  Future<void> _applyAddressing() async {
    await source.send(setHeaderCommand(requestHeader));
    if (responseFilter != null) {
      await source.send(setReceiveFilterCommand(responseFilter!));
    }
  }

  /// Read one DID and classify it.
  Future<DidScanResult> probe(int did) async {
    final didBytes = [(did >> 8) & 0xFF, did & 0xFF];
    final line = requestLine([0x22, ...didBytes],
        extendedAddress: extendedAddress);
    String raw;
    try {
      raw = await source.send(line);
    } on Object {
      return DidScanResult(did, DidStatus.noData);
    }

    List<int>? message;
    try {
      final frames = parseFrames(raw, is29Bit: is29Bit);
      if (frames.isEmpty) return DidScanResult(did, DidStatus.noData);
      message = reassemble(frames.map((f) => f.data));
    } on ElmException {
      return DidScanResult(did, DidStatus.noData);
    } on FormatException {
      return DidScanResult(did, DidStatus.malformed);
    }
    return classify(did, message);
  }

  /// Sweep an inclusive DID range, invoking [onResult] as each completes.
  /// Returns only the interesting (responded) DIDs.
  Future<List<DidScanResult>> sweep({
    required int startDid,
    required int endDid,
    void Function(DidScanResult result)? onResult,
  }) async {
    assert(startDid >= 0 && endDid <= 0xFFFF && startDid <= endDid);
    await _applyAddressing();
    final hits = <DidScanResult>[];
    for (int did = startDid; did <= endDid; did++) {
      final r = await probe(did);
      onResult?.call(r);
      if (r.isInteresting) hits.add(r);
    }
    return hits;
  }
}

/// Turn a set of discovered DIDs into draft signal-set [Command]s (one signal
/// per DID, raw 16-bit placeholder) so a human can then refine offsets/scales.
List<Command> draftCommandsFromHits(
  Iterable<DidScanResult> hits, {
  required String hdr,
  required String rax,
  String? eax,
}) {
  return hits.where((h) => h.isInteresting).map((h) {
    return Command(
      hdr: hdr,
      rax: rax,
      eax: eax,
      service: '22',
      payload: h.didHex,
      signals: [
        Signal(
          id: 'UNKNOWN_${h.didHex}',
          name: 'Unknown DID ${h.didHex} (${h.data?.length ?? 0} bytes)',
          group: 'unclassified',
          fmt: const SignalFormat(bix: 0, len: 16),
        ),
      ],
    );
  }).toList();
}
