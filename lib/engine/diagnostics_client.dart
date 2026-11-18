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

  /// Current BMW extended-addressing mode ("hdr/eax"), or null for normal
  /// auto-formatted ISO-TP (the adapter's state after [initialize]).
  String? _lastExtMode;

  /// Ask for the shortest reply wait that still works, instead of the safe
  /// default. Only affects extended addressing, where the adapter waits a
  /// fixed time after every reply (adaptive timing is off because the ECU
  /// sends "response pending" first): at the default ATSTFF that wait is
  /// ~1 s, which caps a single-signal poll at ~0.8 Hz. Drive mode turns this
  /// on; it takes effect on the next [read].
  ///
  /// Self-correcting: a read that fails while a shorter wait is in use drops
  /// to the next longer one for the rest of the connection, ending at the
  /// default. The worst case is one or two lost samples. Each ECU has its own
  /// ladder, so a slow or silent ECU does not slow the others down.
  bool fastTiming = false;

  /// Reply waits to try, safe default first (ELM `ATST` units of ~4 ms:
  /// FF ~1.04 s, 80 ~0.52 s, 40 ~0.26 s).
  static const _replyWaits = ['FF', '80', '40'];

  /// Per extended-addressing mode ("hdr/eax"): the shortest entry of
  /// [_replyWaits] that has not failed yet for that ECU.
  final Map<String, int> _fastestWait = {};

  int _fastestWaitFor(String mode) =>
      _fastestWait[mode] ?? _replyWaits.length - 1;

  /// The wait the adapter currently has (meaningful in extended mode only).
  String _appliedWait = _replyWaits.first;

  /// Which slow-changing commands (those with a `freq`) are due in [readAll].
  final PollSchedule _schedule = PollSchedule();

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
    _lastExtMode = null;
    _appliedWait = _replyWaits.first;
    _schedule.reset();
  }

  /// Something else used the adapter (terminal, DID scanner, signal check):
  /// its header, receive filter and addressing mode are no longer what this
  /// client last set, so the next read sets all of them again.
  void forgetAdapterState() {
    _lastHdr = null;
    _lastRax = null;
    _lastExtMode = _unknownMode;
    _appliedWait = _replyWaits.first;
  }

  /// [_lastExtMode] when the adapter's addressing mode is not known. Matches
  /// neither normal addressing (null) nor any "hdr/eax".
  static const _unknownMode = '?';

  /// Run one command and return its decoded readings.
  Future<List<Reading>> read(Command command, {DateTime? now}) async {
    try {
      await _applyAddressing(command);

      final line = requestLine(command.requestBytes());
      final raw = await source.send(line);

      final frames = parseFrames(raw, is29Bit: _is29Bit);
      if (frames.isEmpty) {
        throw const FormatException('No CAN frames in response');
      }

      // Reassemble ISO-TP from the data fields (the adapter's receive filter
      // already limited them to the response id).
      final message = reassemble(responseDataFields(frames,
          extendedAddressing: command.eax != null));

      final serviceInt = int.parse(command.service, radix: 16);
      final echo = command.echoedIdentifierBytes();
      final resp = parseResponse(
        message,
        requestService: serviceInt,
        identifierLength: echo.length,
      );
      // The reply must be for THIS request. A slow ECU's answer can arrive
      // after the adapter stopped waiting and surface in the next exchange;
      // decoding it as this command's signals would show a wrong value.
      if (!_sameBytes(resp.identifier, echo)) {
        throw FormatException(
            'Reply is for ${_hex(resp.identifier)}, not ${_hex(echo)} '
            '(late answer to an earlier request)');
      }

      final ts = now ?? DateTime.now();
      // A value on a null bound (e.g. a raw-0 "no reading" sentinel) is
      // dropped rather than shown as a real measurement.
      return [
        for (final s in command.signals)
          if (s.fmt.decodeOrNull(resp.data) case final v?) Reading(s, v, ts),
      ];
    } on CommandFailure {
      _noteFailure(command);
      rethrow;
    } on UdsNegativeResponse catch (e) {
      // The ECU answered in time and said no: not a timing problem.
      throw CommandFailure(command, e);
    } catch (e) {
      _noteFailure(command);
      throw CommandFailure(command, e);
    }
  }

  /// A failed read under a shortened reply wait: assume the wait was too
  /// short and stop using it.
  void _noteFailure(Command command) {
    final mode = _lastExtMode;
    if (command.eax != null &&
        mode != null &&
        _appliedWait != _replyWaits.first) {
      final failed = _replyWaits.indexOf(_appliedWait);
      if (failed > 0 && _fastestWaitFor(mode) >= failed) {
        _fastestWait[mode] = failed - 1;
      }
    }
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static String _hex(List<int> bytes) => bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join();

  /// Read every command in the signal set, skipping ones that fail (so one
  /// unsupported DID doesn't abort the whole poll). Returns readings by id.
  ///
  /// A command with a `freq` is left out until that many seconds have passed
  /// since its last successful read, so the result can hold fewer signals
  /// than the previous poll's; callers merge it into what they already have.
  Future<Map<String, Reading>> readAll({
    void Function(CommandFailure failure)? onFailure,
    DateTime? now,
  }) async {
    final out = <String, Reading>{};
    for (final cmd in signalSet.commands) {
      if (!_schedule.isDue(cmd, now ?? DateTime.now())) continue;
      try {
        for (final r in await read(cmd, now: now)) {
          out[r.signal.id] = r;
        }
        _schedule.markRead(cmd, now ?? DateTime.now());
      } on CommandFailure catch (f) {
        onFailure?.call(f);
      }
    }
    return out;
  }

  Future<void> _applyAddressing(Command command) async {
    // Switch between normal and BMW extended addressing only on a change, so
    // a poll that stays on one ECU doesn't resend the mode commands.
    final mode = command.eax == null ? null : '${command.hdr}/${command.eax}';
    if (mode != _lastExtMode) {
      if (command.eax == null) {
        for (final c in normalAddressingCommands) {
          await source.send(c);
        }
      } else {
        if (command.hdr == null) {
          throw ArgumentError('Extended addressing (eax) requires a hdr');
        }
        for (final c in extendedAddressingCommands(
            hdr: command.hdr!, target: int.parse(command.eax!, radix: 16))) {
          await source.send(c);
        }
        _appliedWait = _replyWaits.first; // the mode commands set ATSTFF
      }
      _lastExtMode = mode;
    }
    if (command.eax != null) {
      final want =
          fastTiming ? _replyWaits[_fastestWaitFor(mode!)] : _replyWaits.first;
      if (want != _appliedWait) {
        await source.send('ATST$want');
        _appliedWait = want;
      }
    }
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
