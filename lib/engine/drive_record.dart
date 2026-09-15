/// Drive Session Report — a recorded, persistable summary of a drive, built
/// for the used-EV buyer: what the pack did under real load.
///
/// Where [DriveSession] is the live rolling view, [DriveRecord] accumulates a
/// whole drive into a keepable, shareable health snapshot. The discharge-side
/// signals it captures are the ones a static or charging read can't show:
///   - peak power delivered (does the pack make its rated output?)
///   - peak regen (is regen limited — cold/full pack, or a fault?)
///   - energy used vs recovered (regen fraction — efficiency + brake health)
///   - MINIMUM pack voltage under load and the current at that moment
///     (voltage sag under a hard pull is the clearest field-detectable sign
///      of a weak/aged pack — high internal resistance)
///   - temperature rise across the drive
///
/// Pure Dart, no Flutter imports. Serialises to JSON for persistence and to a
/// plain-text summary for the shareable report.
library;

import 'dart:convert';

/// One fully-populated sample during a drive. Any field may be null if that
/// signal wasn't read on a given poll (the drive profile prioritises current).
class DriveTick {
  final DateTime t;

  /// Pack power, kW. Positive = discharge (draw), negative = regen.
  final double kw;

  /// Pack current, A (signed, +discharge) — the primary signal.
  final double amps;

  /// Pack voltage at this tick, V, if available (nominal-constant on Lyriq,
  /// but recorded so a vehicle that exposes live V benefits automatically).
  final double? volts;

  /// Representative pack temperature, °C, if available.
  final double? tempC;

  /// Vehicle speed, km/h, if available (dynamics ECU).
  final double? speedKmh;

  const DriveTick({
    required this.t,
    required this.kw,
    required this.amps,
    this.volts,
    this.tempC,
    this.speedKmh,
  });

  Map<String, dynamic> toJson() => {
        't': t.toUtc().toIso8601String(),
        'kw': kw,
        'a': amps,
        if (volts != null) 'v': volts,
        if (tempC != null) 'c': tempC,
        if (speedKmh != null) 's': speedKmh,
      };

  factory DriveTick.fromJson(Map<String, dynamic> j) => DriveTick(
        t: DateTime.parse(j['t'] as String),
        kw: (j['kw'] as num).toDouble(),
        amps: (j['a'] as num).toDouble(),
        volts: (j['v'] as num?)?.toDouble(),
        tempC: (j['c'] as num?)?.toDouble(),
        speedKmh: (j['s'] as num?)?.toDouble(),
      );
}

/// Computed summary of a recorded drive.
class DriveSummary {
  final Duration duration;
  final int sampleCount;
  final double peakDrawKw;
  final double peakRegenKw;
  final double energyUsedKwh;
  final double energyRecoveredKwh;

  /// Regen recovered as a fraction of energy used (0-1); null if none used.
  final double? regenFraction;

  /// Lowest pack voltage seen while under meaningful load, and the current
  /// drawn at that instant. Null if no live voltage was available (e.g. the
  /// Lyriq reports only a nominal constant — then sag can't be measured).
  final double? minLoadedVolts;
  final double? ampsAtMinVolts;

  final double? tempStartC;
  final double? tempEndC;

  /// Max instantaneous discharge current seen, A.
  final double peakAmps;

  const DriveSummary({
    required this.duration,
    required this.sampleCount,
    required this.peakDrawKw,
    required this.peakRegenKw,
    required this.energyUsedKwh,
    required this.energyRecoveredKwh,
    required this.regenFraction,
    required this.minLoadedVolts,
    required this.ampsAtMinVolts,
    required this.tempStartC,
    required this.tempEndC,
    required this.peakAmps,
  });

  double? get tempRiseC =>
      (tempStartC != null && tempEndC != null) ? tempEndC! - tempStartC! : null;
}

class DriveRecord {
  /// Load threshold (A) above which a tick counts as "under load" for the
  /// voltage-sag measurement — ignore coasting/idle where V is unloaded.
  final double loadThresholdAmps;

  /// Gaps longer than this are excluded from energy integrals.
  final Duration maxIntegrationGap;

  final String? vehicle;
  DateTime? startedAt;
  DateTime? endedAt;
  bool finished = false;

  final List<DriveTick> ticks = [];

  DriveRecord({
    this.vehicle,
    this.loadThresholdAmps = 20.0,
    this.maxIntegrationGap = const Duration(seconds: 5),
  });

  void add(DriveTick tick) {
    if (finished) return;
    startedAt ??= tick.t;
    endedAt = tick.t;
    ticks.add(tick);
  }

  void finish() => finished = true;

  DriveSummary summarize() {
    var peakDraw = 0.0, peakRegen = 0.0, peakAmps = 0.0;
    var used = 0.0, recovered = 0.0;
    double? minLoadedV, ampsAtMinV;
    double? tStart, tEnd;
    DriveTick? prev;

    for (final s in ticks) {
      if (s.kw > peakDraw) peakDraw = s.kw;
      if (-s.kw > peakRegen) peakRegen = -s.kw;
      if (s.amps > peakAmps) peakAmps = s.amps;

      // Voltage sag: track the lowest voltage seen while genuinely under load.
      if (s.volts != null && s.amps >= loadThresholdAmps) {
        if (minLoadedV == null || s.volts! < minLoadedV) {
          minLoadedV = s.volts;
          ampsAtMinV = s.amps;
        }
      }
      if (s.tempC != null) {
        tStart ??= s.tempC;
        tEnd = s.tempC;
      }

      if (prev != null && s.t.isAfter(prev.t)) {
        final gap = s.t.difference(prev.t);
        if (gap <= maxIntegrationGap) {
          final dtH = gap.inMilliseconds / 3.6e6;
          final avg = (s.kw + prev.kw) / 2;
          if (avg >= 0) {
            used += avg * dtH;
          } else {
            recovered += -avg * dtH;
          }
        }
      }
      prev = s;
    }

    return DriveSummary(
      duration: (startedAt != null && endedAt != null)
          ? endedAt!.difference(startedAt!)
          : Duration.zero,
      sampleCount: ticks.length,
      peakDrawKw: peakDraw,
      peakRegenKw: peakRegen,
      energyUsedKwh: used,
      energyRecoveredKwh: recovered,
      regenFraction: used > 0 ? recovered / used : null,
      minLoadedVolts: minLoadedV,
      ampsAtMinVolts: ampsAtMinV,
      tempStartC: tStart,
      tempEndC: tEnd,
      peakAmps: peakAmps,
    );
  }

  /// Plain-text buyer-facing report (also the basis for the shareable card).
  String reportText() {
    final s = summarize();
    String kwh(double v) => '${v.toStringAsFixed(2)} kWh';
    final b = StringBuffer()
      ..writeln('EV Drive Health Report')
      ..writeln(vehicle == null ? '' : vehicle!)
      ..writeln('Duration: ${_fmtDur(s.duration)}   Samples: ${s.sampleCount}')
      ..writeln('')
      ..writeln('Peak power delivered: ${s.peakDrawKw.toStringAsFixed(1)} kW '
          '(${s.peakAmps.toStringAsFixed(0)} A)')
      ..writeln('Peak regen: ${s.peakRegenKw.toStringAsFixed(1)} kW')
      ..writeln('Energy used: ${kwh(s.energyUsedKwh)}')
      ..writeln('Energy recovered: ${kwh(s.energyRecoveredKwh)}'
          '${s.regenFraction == null ? '' : ' (${(s.regenFraction! * 100).toStringAsFixed(0)}% of used)'}');
    if (s.minLoadedVolts != null) {
      b.writeln('Min pack voltage under load: '
          '${s.minLoadedVolts!.toStringAsFixed(1)} V '
          'at ${s.ampsAtMinVolts!.toStringAsFixed(0)} A');
    }
    if (s.tempRiseC != null) {
      b.writeln('Battery temp: ${s.tempStartC!.toStringAsFixed(0)} → '
          '${s.tempEndC!.toStringAsFixed(0)} °C '
          '(${s.tempRiseC! >= 0 ? '+' : ''}${s.tempRiseC!.toStringAsFixed(0)})');
    }
    return b.toString().trimRight();
  }

  static String _fmtDur(Duration d) {
    final m = d.inMinutes, sec = d.inSeconds % 60;
    return '${m}m ${sec.toString().padLeft(2, '0')}s';
  }

  Map<String, dynamic> toJson() => {
        if (vehicle != null) 'vehicle': vehicle,
        'startedAt': startedAt?.toUtc().toIso8601String(),
        'endedAt': endedAt?.toUtc().toIso8601String(),
        'finished': finished,
        'loadThresholdAmps': loadThresholdAmps,
        'ticks': ticks.map((t) => t.toJson()).toList(),
      };

  factory DriveRecord.fromJson(Map<String, dynamic> j) {
    final r = DriveRecord(
      vehicle: j['vehicle'] as String?,
      loadThresholdAmps: (j['loadThresholdAmps'] as num?)?.toDouble() ?? 20.0,
    );
    r.startedAt =
        j['startedAt'] == null ? null : DateTime.parse(j['startedAt'] as String);
    r.endedAt =
        j['endedAt'] == null ? null : DateTime.parse(j['endedAt'] as String);
    r.finished = j['finished'] as bool? ?? false;
    for (final e in (j['ticks'] as List? ?? const [])) {
      r.ticks.add(DriveTick.fromJson(e as Map<String, dynamic>));
    }
    return r;
  }

  String toJsonString() => jsonEncode(toJson());
  factory DriveRecord.fromJsonString(String s) =>
      DriveRecord.fromJson(jsonDecode(s) as Map<String, dynamic>);
}
