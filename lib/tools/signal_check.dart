/// Signal check: send every request of a signal set once and record what the
/// vehicle did with each (answered, rejected, silent), with the adapter's raw
/// reply. For a vehicle whose signal set has not been tried on a car (an
/// import, a sibling model's definitions) this is the first thing to run:
/// its report says which requests are real on this vehicle, and holds the
/// raw replies to build replay fixtures from.
///
/// Read-only: it sends exactly the signal set's own read requests, nothing
/// else. Pure Dart; the bus I/O goes through a [DataSource].
library;

import '../engine/diagnostics_client.dart';
import '../engine/signal_set.dart';
import '../protocol/uds.dart';
import '../transport/data_source.dart';
import '../transport/elm327_protocol.dart';

enum CheckStatus {
  /// Positive reply for this request.
  answered,

  /// The control unit answered and said no (negative response).
  rejected,

  /// Nothing came back (NO DATA): no such control unit on this bus, or it
  /// ignores the request.
  silent,

  /// Something came back that is not a usable reply (bus error, garbage, a
  /// reply to another request), or the adapter itself failed.
  failed,
}

class CommandCheck {
  final Command command;
  final CheckStatus status;

  /// What the adapter returned for the request, lines joined by " | ".
  final String raw;

  /// Decoded values when [status] is answered (a value on a null bound is
  /// left out, as in normal polling).
  final List<Reading> readings;

  /// The negative response code when [status] is rejected.
  final int? nrc;

  /// Why, when [status] is failed.
  final String? detail;

  const CommandCheck(this.command, this.status, this.raw,
      {this.readings = const [], this.nrc, this.detail});

  String get request => '${command.service}${command.payload}';
}

/// One raw reply taken back out of a report by [SignalCheck.repliesIn].
typedef CheckedReply = ({
  String? hdr,
  String? rax,
  String? eax,
  String request,
  CheckStatus status,
  String response,
});

class SignalCheck {
  /// Adapter questions whose answers head the report (identity, the 12 V
  /// supply it measures, the protocol it settled on).
  static const adapterQueries = ['ATI', 'ATRV', 'ATDPN'];

  /// Read every command of [set] once, in signal-set order. A silent request
  /// is tried a second time (the first request after switching to another
  /// control unit is the one clones tend to drop). Stops early when
  /// [shouldStop] returns true or the adapter disconnects.
  ///
  /// The adapter must already be initialised for this vehicle's protocol
  /// (the app does that on connect) and not in use by anything else.
  static Future<List<CommandCheck>> run(
    DataSource source,
    SignalSet set, {
    void Function(CommandCheck check)? onResult,
    bool Function()? shouldStop,
  }) async {
    final tap = _Tap(source);
    final client = DiagnosticsClient(tap, set)..forgetAdapterState();
    final out = <CommandCheck>[];
    for (final command in set.commands) {
      if (shouldStop?.call() ?? false) break;
      var check = await _check(client, tap, command);
      if (check.status == CheckStatus.silent && source.isConnected) {
        check = await _check(client, tap, command);
      }
      out.add(check);
      onResult?.call(check);
      if (!source.isConnected) break;
    }
    return out;
  }

  static Future<CommandCheck> _check(
      DiagnosticsClient client, _Tap tap, Command command) async {
    tap.last = '';
    try {
      final readings = await client.read(command);
      return CommandCheck(command, CheckStatus.answered, tap.text,
          readings: readings);
    } on CommandFailure catch (f) {
      final cause = f.cause;
      if (cause is UdsNegativeResponse) {
        return CommandCheck(command, CheckStatus.rejected, tap.text,
            nrc: cause.nrc);
      }
      if (cause is ElmException && cause.token == 'NO DATA') {
        return CommandCheck(command, CheckStatus.silent, tap.text);
      }
      if (cause is FormatException && tap.text.isEmpty) {
        return CommandCheck(command, CheckStatus.silent, tap.text);
      }
      return CommandCheck(command, CheckStatus.failed, tap.text,
          detail: cause is ElmException
              ? cause.token
              : cause is FormatException
                  ? cause.message
                  : '$cause');
    }
  }

  /// The adapter's answers to [adapterQueries], for the report header. A
  /// query that fails is left out.
  static Future<Map<String, String>> adapterInfo(DataSource source) async {
    final info = <String, String>{};
    for (final q in adapterQueries) {
      try {
        final text = replyOnOneLine(await source.send(q));
        if (text.isNotEmpty) info[q] = text;
      } on Object {
        // Not worth failing a check over.
      }
    }
    return info;
  }

  /// The check as text: readable on a phone, and regular enough for
  /// [repliesIn] to take the raw replies back out.
  static String report(
    List<CommandCheck> checks, {
    required SignalSet set,
    required DateTime when,
    String adapter = '',
    Map<String, String> adapterInfo = const {},
  }) {
    int count(CheckStatus s) => checks.where((c) => c.status == s).length;
    String two(int n) => n.toString().padLeft(2, '0');
    final lines = <String>[
      '# Signal check: every request in the signal set, sent once (read-only)',
      '# vehicle: ${set.vehicle}',
      '# when: ${when.year}-${two(when.month)}-${two(when.day)} '
          '${two(when.hour)}:${two(when.minute)}',
      '# adapter: ${[
        if (adapter.isNotEmpty) adapter,
        for (final e in adapterInfo.entries) '${e.key}=${e.value}',
      ].join('  ')}',
      '# answered ${count(CheckStatus.answered)}, '
          'rejected ${count(CheckStatus.rejected)}, '
          'silent ${count(CheckStatus.silent)}, '
          'failed ${count(CheckStatus.failed)} '
          '(of ${set.commands.length} requests)',
    ];
    String? section;
    for (final c in checks) {
      final s = sectionTitle(c.command);
      if (s != section) {
        lines
          ..add('')
          ..add('== $s');
        section = s;
      }
      final note = switch (c.status) {
        CheckStatus.rejected => '  [${_hex2(c.nrc!)} '
            '${udsNrcNames[c.nrc] ?? 'unknown code'}]',
        CheckStatus.failed => '  [${c.detail}]',
        _ => '',
      };
      lines.add('${c.request.padRight(8)}${c.status.name.padRight(10)}'
          '${c.raw.isEmpty ? '(nothing)' : c.raw}$note');
      for (final r in c.readings) {
        final label = r.signal.fmt.labelFor(r.value);
        final value = label == null
            ? '${_number(r.value)} ${r.unit}'.trim()
            : '$label (${_number(r.value)})';
        lines.add('    ${r.signal.id} = $value');
      }
    }
    return '${lines.join('\n')}\n';
  }

  /// "7E4 -> 7EC", "6F1 -> 607 (07)" for BMW extended addressing, or
  /// "default addressing" for a request with no header of its own.
  static String sectionTitle(Command c) {
    if (c.hdr == null) return 'default addressing';
    return '${c.hdr} -> ${c.rax ?? 'any'}'
        '${c.eax == null ? '' : ' (${c.eax})'}';
  }

  static final _sectionLine =
      RegExp(r'^== (?:default addressing|(\w+) -> (\w+)(?: \((\w+)\))?)$');
  static final _requestLine = RegExp(
      r'^([0-9A-F]{2,})\s+(answered|rejected|silent|failed)\s+(.*?)(?:  \[.*\])?$');

  /// The raw replies in a [report], in order, with the addressing each
  /// request was sent under. `response` is in adapter form (lines separated
  /// by CR, closing prompt) so it can go straight into a [ReplaySource].
  static List<CheckedReply> repliesIn(String report) {
    final out = <CheckedReply>[];
    String? hdr, rax, eax;
    for (final line in report.split('\n')) {
      final s = _sectionLine.firstMatch(line);
      if (s != null) {
        hdr = s.group(1);
        rax = s.group(1) == null || s.group(2) == 'any' ? null : s.group(2);
        eax = s.group(3);
        continue;
      }
      final m = _requestLine.firstMatch(line);
      if (m == null) continue;
      final raw = m.group(3)!;
      out.add((
        hdr: hdr,
        rax: rax,
        eax: eax,
        request: m.group(1)!,
        status: CheckStatus.values.byName(m.group(2)!),
        response:
            raw == '(nothing)' ? '\r>' : '${raw.split(' | ').join('\r')}\r>',
      ));
    }
    return out;
  }

  static String _number(double v) {
    if (v == v.roundToDouble() && v.abs() < 1e15) return v.round().toString();
    return v
        .toStringAsFixed(4)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  static String _hex2(int b) =>
      b.toRadixString(16).padLeft(2, '0').toUpperCase();
}

/// Passes everything through and remembers the reply to the last request
/// that was not an adapter (AT) command.
class _Tap implements DataSource {
  final DataSource inner;
  String last = '';
  _Tap(this.inner);

  String get text => replyOnOneLine(last);

  @override
  String get name => inner.name;
  @override
  bool get isConnected => inner.isConnected;
  @override
  Future<void> connect() => inner.connect();
  @override
  Future<void> disconnect() => inner.disconnect();

  @override
  Future<String> send(String command, {Duration? timeout}) async {
    final reply = await inner.send(command, timeout: timeout);
    if (!command.trim().toUpperCase().startsWith('AT')) last = reply;
    return reply;
  }
}
