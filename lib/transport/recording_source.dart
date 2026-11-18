/// Records everything that passes between the app and the adapter, so a
/// session on a vehicle can be taken home from the phone alone: every
/// command (adapter setup included) and the raw reply, one line each, in
/// order, with the time. The same job the Pi-side probe scripts do for our
/// own cars.
///
/// A recording replays: [Recording.parse] gives back each exchange with the
/// header and filter that were set when it was sent. Pure Dart.
library;

import 'data_source.dart';
import 'elm327_protocol.dart';

/// A [DataSource] that passes everything through to [inner] and reports each
/// exchange as one text line to [onLine].
class RecordingSource implements DataSource {
  final DataSource inner;
  final void Function(String line) onLine;
  final DateTime Function() _now;

  RecordingSource(this.inner, this.onLine, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

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
    final at = Recording.clock(_now());
    try {
      final reply = await inner.send(command, timeout: timeout);
      onLine('$at $command -> ${replyOnOneLine(reply)}');
      return reply;
    } on Object catch (e) {
      onLine('$at $command !! ${'$e'.replaceAll(RegExp(r'[\r\n]+'), ' ')}');
      rethrow;
    }
  }
}

/// One line of a recording: a command and what came back.
class RecordedExchange {
  /// Time of day the command was sent, "HH:MM:SS.mmm".
  final String time;
  final String command;

  /// The adapter's reply with its lines joined by " | "; null when the send
  /// itself failed (timeout, disconnected), see [error].
  final String? reply;
  final String? error;

  /// Addressing in force when the command was sent, from the `ATSH`, `ATCRA`
  /// and `ATCEA` commands before it in the recording.
  final String? hdr;
  final String? rax;
  final String? eax;

  const RecordedExchange({
    required this.time,
    required this.command,
    this.reply,
    this.error,
    this.hdr,
    this.rax,
    this.eax,
  });

  /// An adapter (AT) command, as opposed to a request to the vehicle.
  bool get isAdapterCommand => command.toUpperCase().startsWith('AT');

  /// The reply in adapter form (CR between lines, closing prompt), ready for
  /// a [ReplaySource].
  String get response =>
      reply == null ? '\r>' : '${reply!.split(' | ').join('\r')}\r>';
}

class Recording {
  /// Explains the format; goes at the top of every recording.
  static const formatNote =
      '# One line per exchange with the adapter, in order: time, command, '
      "'->' and the reply (its lines joined by ' | '), or '!!' and the "
      'error when nothing usable came back. Lines starting with # are notes.';

  static String clock(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.'
        '${t.millisecond.toString().padLeft(3, '0')}';
  }

  static final _line =
      RegExp(r'^(\d\d:\d\d:\d\d\.\d\d\d) (\S+) (->|!!) ?(.*)$');

  /// The exchanges in a recording. Note lines and anything else that is not
  /// an exchange are skipped.
  static List<RecordedExchange> parse(String text) {
    final out = <RecordedExchange>[];
    String? hdr, rax, eax;
    for (final raw in text.split('\n')) {
      final m = _line.firstMatch(raw.trimRight());
      if (m == null) continue;
      final command = m.group(2)!;
      final ok = m.group(3) == '->';
      out.add(RecordedExchange(
        time: m.group(1)!,
        command: command,
        reply: ok ? m.group(4)! : null,
        error: ok ? null : m.group(4)!,
        hdr: hdr,
        rax: rax,
        eax: eax,
      ));
      // Addressing commands take effect for what follows.
      final upper = command.toUpperCase();
      String? argument(String prefix) =>
          upper.length > prefix.length ? upper.substring(prefix.length) : null;
      if (upper == 'ATZ' || upper == 'ATD') {
        hdr = rax = eax = null;
      } else if (upper.startsWith('ATSH')) {
        hdr = argument('ATSH');
      } else if (upper.startsWith('ATCRA')) {
        rax = argument('ATCRA');
      } else if (upper.startsWith('ATCEA')) {
        eax = argument('ATCEA');
      }
    }
    return out;
  }
}
