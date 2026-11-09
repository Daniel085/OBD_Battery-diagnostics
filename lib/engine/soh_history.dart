/// A long-lived record of battery state-of-health readings, so the app can show
/// how health moves over months and years — something no single read can.
///
/// The ECUs keep no SoH-over-time table of their own (see
/// docs/bmw-330e-sme.md), so the history is ours: every connect contributes at
/// most one entry per vehicle, per source, per calendar day. SoH moves ~1-2
/// points a year, so a daily resolution loses nothing and keeps the file tiny.
///
/// Pure Dart (no Flutter) so it is unit-testable.
library;

import 'dart:convert';

/// Where an SoH figure came from. They answer different questions and are
/// never merged into one series.
enum SohSource {
  /// The battery controller's own SoH register (e.g. BMW SME `6335`).
  reported,

  /// A candidate controller health index not yet confirmed as SoH
  /// (e.g. Lyriq `451D`).
  bmsIndex,

  /// Our coulomb-counted capacity test.
  measured,
}

class SohEntry {
  final DateTime at;
  final String vehicle;
  final SohSource source;
  final double sohPct;
  final double? odometerKm;

  const SohEntry({
    required this.at,
    required this.vehicle,
    required this.source,
    required this.sohPct,
    this.odometerKm,
  });

  Map<String, dynamic> toJson() => {
        'at': at.toUtc().toIso8601String(),
        'vehicle': vehicle,
        'source': source.name,
        'soh': sohPct,
        if (odometerKm != null) 'odo_km': odometerKm,
      };

  factory SohEntry.fromJson(Map<String, dynamic> j) => SohEntry(
        at: DateTime.parse(j['at'] as String),
        vehicle: j['vehicle'] as String,
        source: SohSource.values.byName(j['source'] as String),
        sohPct: (j['soh'] as num).toDouble(),
        odometerKm: (j['odo_km'] as num?)?.toDouble(),
      );
}

/// Linear trend of one series.
class SohTrend {
  /// SoH change per year (negative = losing health).
  final double pctPerYear;

  /// Days between the first and last entry used.
  final int spanDays;

  const SohTrend(this.pctPerYear, this.spanDays);
}

class SohHistory {
  /// Hard cap so a pathological file can't grow without bound. Daily entries
  /// for three sources is ~3k/year; 5000 is years of history per vehicle.
  static const maxEntries = 5000;

  /// Minimum span before a trend is shown: over a few days the slope of an
  /// integer-percent register is noise.
  static const minTrendDays = 30;

  final List<SohEntry> _entries;

  SohHistory([List<SohEntry>? entries]) : _entries = [...?entries];

  List<SohEntry> get entries => List.unmodifiable(_entries);

  /// Add [e], keeping one entry per vehicle + source + local calendar day.
  /// A same-day reading replaces that day's entry only if the value changed,
  /// so a steady value does not rewrite the file every poll. Returns true if
  /// the history changed (and should be saved).
  bool record(SohEntry e) {
    if (!(e.sohPct > 0 && e.sohPct <= 100)) return false; // 0 = unavailable
    final i = _entries.lastIndexWhere((x) =>
        x.vehicle == e.vehicle &&
        x.source == e.source &&
        _sameDay(x.at, e.at));
    if (i >= 0) {
      final old = _entries[i];
      if (old.sohPct == e.sohPct &&
          (e.odometerKm == null || old.odometerKm == e.odometerKm)) {
        return false;
      }
      _entries[i] = e;
      return true;
    }
    _entries.add(e);
    _entries.sort((a, b) => a.at.compareTo(b.at));
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
    return true;
  }

  /// One vehicle's entries from one source, oldest first.
  List<SohEntry> series(String vehicle, SohSource source) => _entries
      .where((x) => x.vehicle == vehicle && x.source == source)
      .toList(growable: false);

  /// Least-squares slope in % per year, or null until the series spans at
  /// least [minTrendDays] with 3+ entries.
  SohTrend? trend(String vehicle, SohSource source) {
    final s = series(vehicle, source);
    if (s.length < 3) return null;
    final spanDays = s.last.at.difference(s.first.at).inDays;
    if (spanDays < minTrendDays) return null;
    final t0 = s.first.at.millisecondsSinceEpoch;
    final xs = [
      for (final e in s) (e.at.millisecondsSinceEpoch - t0) / 8.64e7 / 365.25
    ];
    final ys = [for (final e in s) e.sohPct];
    final n = xs.length;
    final mx = xs.reduce((a, b) => a + b) / n;
    final my = ys.reduce((a, b) => a + b) / n;
    var sxy = 0.0, sxx = 0.0;
    for (var i = 0; i < n; i++) {
      sxy += (xs[i] - mx) * (ys[i] - my);
      sxx += (xs[i] - mx) * (xs[i] - mx);
    }
    if (sxx == 0) return null;
    return SohTrend(sxy / sxx, spanDays);
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'entries': [for (final e in _entries) e.toJson()],
      };

  String toJsonString() => jsonEncode(toJson());

  factory SohHistory.fromJson(Map<String, dynamic> j) => SohHistory([
        for (final e in (j['entries'] as List? ?? const []))
          SohEntry.fromJson(e as Map<String, dynamic>),
      ]);

  factory SohHistory.fromJsonString(String s) =>
      SohHistory.fromJson(jsonDecode(s) as Map<String, dynamic>);

  static bool _sameDay(DateTime a, DateTime b) {
    final la = a.toLocal(), lb = b.toLocal();
    return la.year == lb.year && la.month == lb.month && la.day == lb.day;
  }
}
