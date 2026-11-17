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

  /// One line for the vehicle picker: what the set covers and how far it
  /// has been checked.
  final String note;
  const VehicleEntry(this.id, this.displayName, this.assetPath,
      {this.note = ''});
}

class SignalSetRepository {
  static const List<VehicleEntry> catalogue = [
    VehicleEntry('BMW-330e-2018', 'BMW 330e (2018, F30 PHEV)',
        'signalsets/BMW-330e-2018/v02.json',
        note: 'Battery manager (SOC, SOH, cell V/temps) '
            '— confirmed on-vehicle'),
    VehicleEntry('Cadillac-Lyriq-2025', 'Cadillac Lyriq (2025, Ultium)',
        'signalsets/Cadillac-Lyriq-2025/v02.json',
        note: 'Pack current, temps, module voltages + '
            'capacity test — confirmed on-vehicle'),
    // Imported from OBDb (tools/obdb-import); not read on a vehicle by us.
    VehicleEntry('Ford-F-150-Lightning-2022', 'Ford F-150 Lightning (2022–2025)',
        'signalsets/Ford-F-150-Lightning-2022/v01.json',
        note: 'SOC, SOH, pack V/A, temps, 12 V, charger, motor '
            '— community data (OBDb), not yet tried by us'),
    VehicleEntry(
        'Ford-F-150-Hybrid-2021', 'Ford F-150 PowerBoost hybrid (2021+)',
        'signalsets/Ford-F-150-Hybrid-2021/v01.json',
        note: '12 V battery and basics from community data (OBDb); '
            'hybrid battery signals are unconfirmed guesses'),
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
