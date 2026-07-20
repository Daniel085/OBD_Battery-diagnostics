/// In-memory model of a per-vehicle signal set (OBDb v3 JSON schema).
///
/// A signal set is a list of [Command]s. Each command is one request (a UDS
/// service + payload, or a J1979 mode + PID) addressed to an ECU, plus the list
/// of [Signal]s decoded from that command's response payload.
library;

import 'dart:convert';

import 'formula.dart';

export 'formula.dart' show SignalFormat;

enum CanFormat { bits11, bits29 }

CanFormat _canFormatFromString(String s) {
  switch (s) {
    case '11bit':
      return CanFormat.bits11;
    case '29bit':
      return CanFormat.bits29;
    default:
      throw FormatException('Unknown canFormat: $s');
  }
}

class Protocol {
  final CanFormat canFormat;
  final int? obdProtocol;
  final String? note;

  const Protocol({required this.canFormat, this.obdProtocol, this.note});

  factory Protocol.fromJson(Map<String, dynamic> j) => Protocol(
        canFormat: _canFormatFromString(j['canFormat'] as String),
        obdProtocol: (j['obdProtocol'] as num?)?.toInt(),
        note: j['note'] as String?,
      );
}

class Signal {
  final String id;
  final String name;
  final String? group;
  final SignalFormat fmt;

  const Signal({
    required this.id,
    required this.name,
    this.group,
    required this.fmt,
  });

  factory Signal.fromJson(Map<String, dynamic> j) => Signal(
        id: j['id'] as String,
        name: j['name'] as String,
        group: j['group'] as String?,
        fmt: SignalFormat.fromJson(j['fmt'] as Map<String, dynamic>),
      );
}

class Command {
  /// Request CAN id / tester address (hex string, e.g. "6F1"). Sent via AT SH.
  final String? hdr;

  /// Expected response CAN id (hex string, e.g. "607"). Sent via AT CRA.
  final String? rax;

  /// Optional extended/target address byte for BMW tester addressing (e.g. "07").
  final String? eax;

  /// UDS/J1979 service byte (hex, e.g. "22", "01", "19").
  final String service;

  /// Service payload (hex, e.g. a 2-byte DID "DDBC" or 1-byte PID "0C").
  /// May be empty for services that take no argument.
  final String payload;

  final List<Signal> signals;

  const Command({
    this.hdr,
    this.rax,
    this.eax,
    required this.service,
    required this.payload,
    required this.signals,
  });

  factory Command.fromJson(Map<String, dynamic> j) {
    final cmd = (j['cmd'] as Map<String, dynamic>);
    if (cmd.length != 1) {
      throw const FormatException('cmd must have exactly one {service: payload} entry');
    }
    final entry = cmd.entries.first;
    return Command(
      hdr: j['hdr'] as String?,
      rax: j['rax'] as String?,
      eax: j['eax'] as String?,
      service: entry.key,
      payload: (entry.value as String? ?? ''),
      signals: (j['signals'] as List<dynamic>? ?? const [])
          .map((s) => Signal.fromJson(s as Map<String, dynamic>))
          .toList(growable: false),
    );
  }

  /// The request bytes to send as the UDS/J1979 message data (service + payload).
  /// e.g. service "22" + payload "DDBC" -> [0x22, 0xDD, 0xBC].
  List<int> requestBytes() => _hexToBytes(service + payload);

  /// The identifier bytes that a valid response will echo back, immediately
  /// after the positive-response service byte (service | 0x40):
  ///  - UDS 0x22: the 2-byte DID.
  ///  - J1979 0x01: the 1-byte PID.
  ///  - others: whatever the payload was (best effort).
  List<int> echoedIdentifierBytes() => _hexToBytes(payload);
}

class SignalSet {
  final String vehicle;
  final String? description;
  final Protocol protocol;
  final List<Command> commands;

  const SignalSet({
    required this.vehicle,
    this.description,
    required this.protocol,
    required this.commands,
  });

  factory SignalSet.fromJson(Map<String, dynamic> j) => SignalSet(
        vehicle: j['vehicle'] as String,
        description: j['description'] as String?,
        protocol: Protocol.fromJson(j['protocol'] as Map<String, dynamic>),
        commands: (j['commands'] as List<dynamic>)
            .map((c) => Command.fromJson(c as Map<String, dynamic>))
            .toList(growable: false),
      );

  factory SignalSet.parse(String jsonSource) =>
      SignalSet.fromJson(jsonDecode(jsonSource) as Map<String, dynamic>);

  /// All signals across all commands, keyed by signal id.
  Map<String, Signal> get signalsById {
    final m = <String, Signal>{};
    for (final c in commands) {
      for (final s in c.signals) {
        m[s.id] = s;
      }
    }
    return m;
  }
}

List<int> _hexToBytes(String hex) {
  final clean = hex.replaceAll(RegExp(r'\s'), '');
  if (clean.length.isOdd) {
    throw FormatException('Hex string must have even length: "$hex"');
  }
  final out = <int>[];
  for (int i = 0; i < clean.length; i += 2) {
    out.add(int.parse(clean.substring(i, i + 2), radix: 16));
  }
  return out;
}
