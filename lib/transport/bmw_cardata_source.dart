/// BMW CarData telematics source (Phase 7, optional / feature-flagged).
///
/// Unlike the OBD path, CarData is BMW's official cloud telematics API — it
/// yields vehicle data WITHOUT a plug, but is BMW-specific, quota-limited
/// (~50 REST calls / 24h), OAuth2-gated, and EU-first (US availability
/// uncertain). It therefore does NOT implement the ELM327 [DataSource]
/// `send(command)` contract; instead it exposes decoded telemetry directly and
/// maps BMW "descriptors" onto the same internal signal ids the OBD path uses,
/// so the dashboard/report code is unchanged.
///
/// This file is a SCAFFOLD: the network client is intentionally abstracted
/// behind [CarDataApi] so credentials/OAuth are supplied by the app, never
/// hardcoded, and so it can be unit-tested with a fake. Wire a real HTTP/MQTT
/// implementation before enabling the feature flag.
library;

import '../engine/diagnostics_client.dart';
import '../engine/signal_set.dart';

/// Maps a BMW CarData descriptor name to an internal signal id + how to interpret
/// it. Descriptor names come from BMW's telematics catalogue.
class CarDataMapping {
  final String descriptor; // e.g. "vehicle.powertrain.electric.battery.stateOfCharge"
  final String signalId; // e.g. "HVBAT_SOC"
  final String name;
  final String unit;
  final String? group;
  const CarDataMapping({
    required this.descriptor,
    required this.signalId,
    required this.name,
    required this.unit,
    this.group,
  });
}

/// Default descriptor→signal mappings for BMW PHEV/EV battery telemetry.
/// Descriptor strings are placeholders to be confirmed against BMW's live
/// CarData catalogue for the specific model before enabling.
const List<CarDataMapping> defaultBmwMappings = [
  CarDataMapping(
    descriptor: 'vehicle.powertrain.electric.battery.stateOfCharge',
    signalId: 'HVBAT_SOC',
    name: 'HV battery SOC',
    unit: 'percent',
    group: 'summary',
  ),
  CarDataMapping(
    descriptor: 'vehicle.powertrain.electric.battery.stateOfHealth',
    signalId: 'HVBAT_SOH',
    name: 'HV battery SOH',
    unit: 'percent',
    group: 'summary',
  ),
];

/// Abstraction over the CarData transport (REST poll and/or MQTT stream). The
/// app supplies a concrete implementation with real OAuth2 tokens; tests supply
/// a fake. Returns raw descriptor→value pairs.
abstract interface class CarDataApi {
  /// One-shot fetch of the latest telematics snapshot (a REST call — counts
  /// against the daily quota). Returns descriptor -> numeric value.
  Future<Map<String, double>> fetchLatest();

  /// Continuous stream of descriptor updates via the MQTT stream, if enabled.
  Stream<MapEntry<String, double>> stream();
}

/// Turns CarData descriptor values into engine [Reading]s using the mapping
/// table, so the rest of the app treats them like OBD readings.
class BmwCarDataSource {
  final CarDataApi api;
  final List<CarDataMapping> mappings;

  BmwCarDataSource(this.api, {this.mappings = defaultBmwMappings});

  Map<String, CarDataMapping> get _byDescriptor =>
      {for (final m in mappings) m.descriptor: m};

  Reading? _toReading(String descriptor, double value, DateTime at) {
    final m = _byDescriptor[descriptor];
    if (m == null) return null;
    final signal = Signal(
      id: m.signalId,
      name: m.name,
      group: m.group,
      fmt: SignalFormat(len: 16, unit: m.unit),
    );
    return Reading(signal, value, at);
  }

  /// Poll once and return mapped readings keyed by signal id.
  Future<Map<String, Reading>> readLatest({DateTime? now}) async {
    final at = now ?? DateTime.now();
    final raw = await api.fetchLatest();
    final out = <String, Reading>{};
    for (final e in raw.entries) {
      final r = _toReading(e.key, e.value, at);
      if (r != null) out[r.signal.id] = r;
    }
    return out;
  }

  /// Stream mapped readings as CarData descriptors arrive.
  Stream<Reading> readings() async* {
    await for (final e in api.stream()) {
      final r = _toReading(e.key, e.value, DateTime.now());
      if (r != null) yield r;
    }
  }
}
