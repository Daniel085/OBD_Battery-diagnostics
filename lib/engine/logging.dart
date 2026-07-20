/// Storage-agnostic time-series logging of readings.
///
/// The engine emits [LogSample]s; a [SampleSink] persists them. An in-memory
/// sink and a CSV serialiser live here (testable without Flutter). The Flutter
/// app supplies a `drift`/SQLite-backed sink implementing the same interface.
library;

import 'diagnostics_client.dart';

/// One timestamped set of readings from a single poll cycle.
class LogSample {
  final DateTime timestamp;
  final Map<String, double> values; // signal id -> value

  LogSample(this.timestamp, this.values);

  factory LogSample.fromReadings(Map<String, Reading> readings, {DateTime? at}) {
    return LogSample(
      at ?? DateTime.now(),
      {for (final e in readings.entries) e.key: e.value.value},
    );
  }
}

abstract interface class SampleSink {
  Future<void> add(LogSample sample);
  Future<void> close();
}

/// Keeps samples in memory (for tests and short sessions).
class InMemorySampleSink implements SampleSink {
  final List<LogSample> samples = [];

  @override
  Future<void> add(LogSample sample) async => samples.add(sample);

  @override
  Future<void> close() async {}

  /// Wide CSV: timestamp column + one column per signal id seen. Sparse cells
  /// (a signal missing from a given sample) are left blank.
  String toCsv() {
    final ids = <String>{};
    for (final s in samples) {
      ids.addAll(s.values.keys);
    }
    final ordered = ids.toList()..sort();
    final rows = <String>['timestamp,${ordered.join(',')}'];
    for (final s in samples) {
      final cells = ordered.map((id) => s.values[id]?.toString() ?? '').join(',');
      rows.add('${s.timestamp.toUtc().toIso8601String()},$cells');
    }
    return rows.join('\n');
  }
}
