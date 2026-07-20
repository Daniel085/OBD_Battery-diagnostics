/// Loads bundled signal sets from app assets and exposes the catalogue of
/// supported vehicles. New vehicles are added by dropping a JSON file into
/// `signalsets/<vehicle>/vNN.json` and registering it here + in pubspec assets.
library;

import 'package:flutter/services.dart' show rootBundle;

import '../engine/signal_set.dart';

class VehicleEntry {
  final String id; // e.g. "BMW-330e-2018"
  final String displayName; // e.g. "BMW 330e (2018, F30 PHEV)"
  final String assetPath;
  const VehicleEntry(this.id, this.displayName, this.assetPath);
}

class SignalSetRepository {
  static const List<VehicleEntry> catalogue = [
    VehicleEntry('BMW-330e-2018', 'BMW 330e (2018, F30 PHEV)',
        'signalsets/BMW-330e-2018/v01.json'),
    VehicleEntry('Cadillac-Lyriq-2025', 'Cadillac Lyriq (2025, Ultium)',
        'signalsets/Cadillac-Lyriq-2025/v01.json'),
  ];

  final Map<String, SignalSet> _cache = {};

  Future<SignalSet> load(VehicleEntry entry) async {
    final cached = _cache[entry.id];
    if (cached != null) return cached;
    final json = await rootBundle.loadString(entry.assetPath);
    final set = SignalSet.parse(json);
    _cache[entry.id] = set;
    return set;
  }
}
