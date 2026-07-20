/// Transport abstraction: something that can exchange text lines with an
/// ELM327-style adapter. Implemented by a real BLE socket (`ElmBleSource`) and
/// by `ReplaySource` for offline tests. Higher layers never touch BLE directly.
library;

/// A bidirectional command/response channel to an ELM327-style adapter.
///
/// [send] writes a single command (CR appended by the implementation) and
/// returns the raw response text up to and including the `>` prompt.
abstract interface class DataSource {
  /// Human-readable adapter identity (for logs/UI). May be empty pre-connect.
  String get name;

  bool get isConnected;

  Future<void> connect();

  /// Send one command line, await the full response text (terminated by `>`).
  Future<String> send(String command, {Duration? timeout});

  Future<void> disconnect();
}

/// A scripted [DataSource] for tests: maps an exact command string to a canned
/// response. Unmapped commands return a default (usually the prompt) or throw.
class ReplaySource implements DataSource {
  final Map<String, String> _script;
  final bool throwOnMiss;
  bool _connected = false;
  final List<String> sentLog = [];

  ReplaySource(Map<String, String> script, {this.throwOnMiss = false})
      : _script = Map.of(script);

  @override
  String get name => 'ReplaySource';

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect() async => _connected = true;

  @override
  Future<String> send(String command, {Duration? timeout}) async {
    sentLog.add(command);
    final key = command.trim().toUpperCase();
    final hit = _script[key] ?? _script[command];
    if (hit != null) return hit;
    if (throwOnMiss) {
      throw StateError('ReplaySource: no scripted response for "$command"');
    }
    return '\r>'; // benign "OK-ish" default for AT setup commands
  }

  @override
  Future<void> disconnect() async => _connected = false;
}
