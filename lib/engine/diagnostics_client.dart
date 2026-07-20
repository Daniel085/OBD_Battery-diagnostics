/// Orchestrates one full request→decode cycle over a [DataSource].
///
/// Given a [Command] from a signal set, it configures the ELM327 (header +
/// receive filter), sends the request, parses the returned CAN frames,
/// reassembles ISO-TP, parses the UDS/J1979 response, and decodes each signal.
///
/// This is the seam between the pure protocol/engine code and the transport.
/// It is transport-agnostic, so `ReplaySource` exercises the entire path in CI.
library;

import '../protocol/isotp.dart';
import '../protocol/uds.dart';
import '../transport/data_source.dart';
import '../transport/elm327_protocol.dart';
import 'signal_set.dart';

/// A decoded reading for one signal.
class Reading {
  final Signal signal;
  final double value;
  final DateTime timestamp;

  Reading(this.signal, this.value, this.timestamp);

  String get unit => signal.fmt.unit ?? '';

  @override
  String toString() =>
      '${signal.id}=${value.toStringAsFixed(3)}${unit.isEmpty ? '' : ' $unit'}';
}

/// Raised when a command could not be read (adapter error, no data, bad frame).
class CommandFailure implements Exception {
  final Command command;
  final Object cause;
  CommandFailure(this.command, this.cause);
  @override
  String toString() =>
      'CommandFailure(${command.service}${command.payload}): $cause';
}

class DiagnosticsClient {
  final DataSource source;
  final SignalSet signalSet;

  /// Tracks the last header/filter set so we skip redundant AT commands.
  String? _lastHdr;
  String? _lastRax;

  DiagnosticsClient(this.source, this.signalSet);

  bool get _is29Bit => signalSet.protocol.canFormat == CanFormat.bits29;

  /// Send the adapter through its init sequence for this signal set's protocol.
  Future<void> initialize() async {
    for (final cmd in initCommands(
        obdProtocol: signalSet.protocol.obdProtocol ?? 6)) {
      await source.send(cmd);
    }
    _lastHdr = null;
    _lastRax = null;
  }

  /// Run one command and return its decoded readings.
  Future<List<Reading>> read(Command command, {DateTime? now}) async {
    try {
      await _applyAddressing(command);

      final line = requestLine(
        command.requestBytes(),
        extendedAddress:
            command.eax != null ? int.parse(command.eax!, radix: 16) : null,
      );
      final raw = await source.send(line);

      final frames = parseFrames(raw, is29Bit: _is29Bit);
      if (frames.isEmpty) {
        throw const FormatException('No CAN frames in response');
      }

      // Reassemble ISO-TP from the data fields of frames matching the response
      // id (if a filter/rax was given, the adapter already filtered).
      final message = reassemble(frames.map((f) => f.data));

      final serviceInt = int.parse(command.service, radix: 16);
      final resp = parseResponse(
        message,
        requestService: serviceInt,
        identifierLength: command.echoedIdentifierBytes().length,
      );

      final ts = now ?? DateTime.now();
      return command.signals
          .map((s) => Reading(s, s.fmt.decode(resp.data), ts))
          .toList(growable: false);
    } on CommandFailure {
      rethrow;
    } catch (e) {
      throw CommandFailure(command, e);
    }
  }

  /// Read every command in the signal set, skipping ones that fail (so one
  /// unsupported DID doesn't abort the whole poll). Returns readings by id.
  Future<Map<String, Reading>> readAll({
    void Function(CommandFailure failure)? onFailure,
    DateTime? now,
  }) async {
    final out = <String, Reading>{};
    for (final cmd in signalSet.commands) {
      try {
        for (final r in await read(cmd, now: now)) {
          out[r.signal.id] = r;
        }
      } on CommandFailure catch (f) {
        onFailure?.call(f);
      }
    }
    return out;
  }

  Future<void> _applyAddressing(Command command) async {
    if (command.hdr != null && command.hdr != _lastHdr) {
      await source.send(setHeaderCommand(command.hdr!));
      _lastHdr = command.hdr;
    }
    if (command.rax != null && command.rax != _lastRax) {
      await source.send(setReceiveFilterCommand(command.rax!));
      _lastRax = command.rax;
    }
  }
}
