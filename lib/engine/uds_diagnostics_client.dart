/// Drives a signal set over a [UdsTransport] (e.g. DoIP/ENET), for links that
/// deliver complete UDS messages rather than ELM327 CAN frames.
///
/// The decode path is identical to the ELM client — parse the UDS response,
/// then apply each signal's formula — but there is no ISO-TP reassembly or AT
/// addressing here: the transport already returns the assembled UDS bytes, and
/// the target ECU address comes from the command's response id (`rax`).
library;

import '../protocol/uds.dart';
import '../transport/uds_transport.dart';
import 'diagnostics_client.dart' show Reading, CommandFailure;
import 'signal_set.dart';

class UdsDiagnosticsClient {
  final UdsTransport transport;
  final SignalSet signalSet;

  UdsDiagnosticsClient(this.transport, this.signalSet);

  /// The ECU target address for a command. Uses the response id (`rax`) — for
  /// DoIP the logical target we address is the ECU whose response we want
  /// (e.g. BMW SME 0x0607). Falls back to `hdr` if `rax` is absent.
  int _targetOf(Command c) {
    final hex = c.rax ?? c.hdr;
    if (hex == null) {
      throw ArgumentError('Command has no target address (rax/hdr)');
    }
    return int.parse(hex, radix: 16);
  }

  Future<List<Reading>> read(Command command, {DateTime? now}) async {
    try {
      final target = _targetOf(command);
      final response =
          await transport.request(target, command.requestBytes());
      final serviceInt = int.parse(command.service, radix: 16);
      final resp = parseResponse(
        response,
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
}
