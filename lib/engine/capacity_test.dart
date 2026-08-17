/// Charge-session capacity test: coulomb-counting between charge cutoffs.
///
/// The one battery metric no reachable controller reports on the Lyriq is
/// capacity/SOH (the BECM's registers are gateway-blocked or unimplemented —
/// see docs/lyriq-did-map.md), so we measure it: integrate pack current
/// (HVBAT_CURRENT, ECU 17 DID 2414, negative = charging) over a charge
/// session, pair the result with dash-read SOC endpoints, and extrapolate
/// pack capacity → SOH against the rated capacity.
///
/// Designed for INTERMITTENT sampling. The phone won't stay connected for a
/// 5-10 h charge; AC charge current is near-constant (measured −22.75 ±0.3 A
/// at 9 kW for hours), so sparse samples integrate accurately. Policy:
///
///  * A charge segment is bounded only by OBSERVED evidence: a sample above
///    the charging threshold (charger off) ends it. A gap between two
///    charging samples — even hours — is interpolated, never split: a gap IS
///    the normal case, and the error model + coverage metric report the
///    uncertainty honestly instead of silently undercounting.
///  * Error bars: linear-interpolation jitter (½·|Δi|·Δt per interval) plus
///    edge terms — a charge start/stop seen only as "charging here, idle
///    there" contributes ½·|i|·gap, the worst-case timing uncertainty.
///  * Everything serialises to JSON so a session survives app restarts and
///    days-long test windows.
///
/// Pure Dart; validated in CI against the real 2026-08-15 Lyriq charge log
/// (captures/2026-08-14-capacity-hunt/chglog.txt).
library;

import 'dart:convert';

/// One timestamped pack-current sample. Sign: negative = charging (into the
/// pack), positive = discharging — the ECU 17 `2414` convention.
class CurrentSample {
  final DateTime t;
  final double amps;
  const CurrentSample(this.t, this.amps);

  Map<String, dynamic> toJson() =>
      {'t': t.toUtc().toIso8601String(), 'a': amps};
  factory CurrentSample.fromJson(Map<String, dynamic> j) =>
      CurrentSample(DateTime.parse(j['t'] as String), (j['a'] as num).toDouble());
}

class CapacityTestConfig {
  /// Current magnitude (A) above which a negative sample counts as charging.
  /// Well below any real AC rate (~11 A at 240 V/2.4 kW) and above idle noise
  /// (±1 A observed in Ready).
  final double chargingThresholdAmps;

  /// Pack nominal voltage for Ah→kWh (ECU 17 `2429` reads a constant 352.1 V;
  /// GM's own capacity bookkeeping is against nominal, so ours is too).
  final double nominalPackVoltage;

  /// Rated pack energy the SOH is graded against (Lyriq: 102 kWh).
  final double ratedKwh;

  /// Sample spacing at or below this counts as fully-covered time in the
  /// coverage metric; longer gaps count only this much as covered.
  final Duration goodSpacing;

  const CapacityTestConfig({
    this.chargingThresholdAmps = 2.0,
    this.nominalPackVoltage = 352.1,
    this.ratedKwh = 102.0,
    this.goodSpacing = const Duration(minutes: 5),
  });

  Map<String, dynamic> toJson() => {
        'chargingThresholdAmps': chargingThresholdAmps,
        'nominalPackVoltage': nominalPackVoltage,
        'ratedKwh': ratedKwh,
        'goodSpacingSec': goodSpacing.inSeconds,
      };
  factory CapacityTestConfig.fromJson(Map<String, dynamic> j) =>
      CapacityTestConfig(
        chargingThresholdAmps: (j['chargingThresholdAmps'] as num).toDouble(),
        nominalPackVoltage: (j['nominalPackVoltage'] as num).toDouble(),
        ratedKwh: (j['ratedKwh'] as num).toDouble(),
        goodSpacing: Duration(seconds: j['goodSpacingSec'] as int),
      );
}

/// One contiguous run of charging samples (bounded by observed idle samples
/// or the ends of the data).
class ChargeSegment {
  final DateTime start;
  final DateTime end;
  final int sampleCount;

  /// Charge delivered in this segment, POSITIVE Ah.
  final double ah;

  /// Interpolation uncertainty within the segment (Ah).
  final double jitterErrAh;
  final double meanAmps;
  final Duration largestGap;

  const ChargeSegment({
    required this.start,
    required this.end,
    required this.sampleCount,
    required this.ah,
    required this.jitterErrAh,
    required this.meanAmps,
    required this.largestGap,
  });

  Duration get duration => end.difference(start);
}

/// Everything the UI needs to render the test, derived from the sample list.
class CapacityAnalysis {
  final List<ChargeSegment> segments;

  /// Total charge delivered, POSITIVE Ah, and its uncertainty.
  final double chargedAh;
  final double errAh;
  final double chargedKwh;

  /// Fraction (0-1) of charging time with sample spacing ≤ goodSpacing.
  final double coverage;
  final Duration largestGap;

  /// Whether the newest sample shows active charging.
  final bool chargingNow;

  /// Extrapolated pack totals — null until both SOC endpoints are set and
  /// differ.
  final double? packAh;
  final double? packKwh;
  final double? sohPct;

  const CapacityAnalysis({
    required this.segments,
    required this.chargedAh,
    required this.errAh,
    required this.chargedKwh,
    required this.coverage,
    required this.largestGap,
    required this.chargingNow,
    this.packAh,
    this.packKwh,
    this.sohPct,
  });
}

class CapacityTestSession {
  final CapacityTestConfig config;
  final DateTime startedAt;
  DateTime? finishedAt;

  /// Dash-read SOC endpoints (percent). The OBD port exposes no SOC on this
  /// vehicle (gateway-blocked), so the user supplies what the dash showed at
  /// charge start and end — ideally charge-target cutoffs, which are the only
  /// trustworthy anchors (mid-charge dash % is laggy/nonlinear).
  double? socStartPct;
  double? socEndPct;

  final List<CurrentSample> samples = [];

  CapacityTestSession({
    CapacityTestConfig? config,
    DateTime? startedAt,
  })  : config = config ?? const CapacityTestConfig(),
        startedAt = startedAt ?? DateTime.now();

  bool get isFinished => finishedAt != null;

  /// Add a sample, keeping the list time-ordered (out-of-order arrivals are
  /// inserted, not appended, so replayed/merged data stays correct).
  void addSample(DateTime t, double amps) {
    if (isFinished) return;
    final s = CurrentSample(t, amps);
    if (samples.isEmpty || !t.isBefore(samples.last.t)) {
      samples.add(s);
      return;
    }
    var lo = 0, hi = samples.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (samples[mid].t.isBefore(t)) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    samples.insert(lo, s);
  }

  void finish({DateTime? at}) => finishedAt ??= at ?? DateTime.now();

  bool _isCharging(double amps) => amps <= -config.chargingThresholdAmps;

  CapacityAnalysis analyze() {
    // Split into runs of charging samples, breaking ONLY on an observed
    // non-charging sample.
    final runs = <List<CurrentSample>>[];
    var run = <CurrentSample>[];
    for (final s in samples) {
      if (_isCharging(s.amps)) {
        run.add(s);
      } else if (run.isNotEmpty) {
        runs.add(run);
        run = <CurrentSample>[];
      }
    }
    if (run.isNotEmpty) runs.add(run);

    final segments = <ChargeSegment>[];
    var chargedAh = 0.0;
    var errAh = 0.0;
    var covered = 0.0; // hours with good spacing
    var chargingTime = 0.0; // hours
    var largestGap = Duration.zero;

    for (final r in runs) {
      var ah = 0.0;
      var jitter = 0.0;
      var segGap = Duration.zero;
      for (var i = 0; i + 1 < r.length; i++) {
        final dtH = r[i + 1].t.difference(r[i].t).inMilliseconds / 3.6e6;
        ah += -dtH * (r[i].amps + r[i + 1].amps) / 2;
        jitter += (r[i + 1].amps - r[i].amps).abs() / 2 * dtH;
        final gap = r[i + 1].t.difference(r[i].t);
        if (gap > segGap) segGap = gap;
        chargingTime += dtH;
        final goodH = config.goodSpacing.inMilliseconds / 3.6e6;
        covered += dtH < goodH ? dtH : goodH;
      }
      final meanAmps =
          r.map((s) => s.amps).reduce((a, b) => a + b) / r.length;
      segments.add(ChargeSegment(
        start: r.first.t,
        end: r.last.t,
        sampleCount: r.length,
        ah: ah,
        jitterErrAh: jitter,
        meanAmps: meanAmps,
        largestGap: segGap,
      ));
      chargedAh += ah;
      errAh += jitter;
      if (segGap > largestGap) largestGap = segGap;

      // Edge terms: the charge started/ended somewhere inside the interval
      // between the boundary charging sample and the nearest observation
      // outside the run (an idle sample, or the session start/finish time).
      errAh += _edgeErrAh(r.first, before: true);
      errAh += _edgeErrAh(r.last, before: false);
    }

    final chargingNow =
        !isFinished && samples.isNotEmpty && _isCharging(samples.last.amps);

    double? packAh, packKwh, sohPct;
    final s0 = socStartPct, s1 = socEndPct;
    if (s0 != null && s1 != null && s1 > s0 && chargedAh > 0) {
      packAh = chargedAh * 100 / (s1 - s0);
      packKwh = packAh * config.nominalPackVoltage / 1000;
      sohPct = packKwh / config.ratedKwh * 100;
    }

    return CapacityAnalysis(
      segments: segments,
      chargedAh: chargedAh,
      errAh: errAh,
      chargedKwh: chargedAh * config.nominalPackVoltage / 1000,
      coverage: chargingTime <= 0
          ? 1.0
          : (covered / chargingTime).clamp(0.0, 1.0).toDouble(),
      largestGap: largestGap,
      chargingNow: chargingNow,
      packAh: packAh,
      packKwh: packKwh,
      sohPct: sohPct,
    );
  }

  /// Worst-case timing uncertainty (Ah) for a charge edge observed only as
  /// "charging at [edge], not charging at the nearest outer observation":
  /// the transition happened somewhere in that window, so the expected error
  /// is half of |i|·gap. An open trailing edge on an unfinished session costs
  /// nothing — the charge simply continues.
  double _edgeErrAh(CurrentSample edge, {required bool before}) {
    DateTime? bound;
    if (before) {
      CurrentSample? prev;
      for (final s in samples) {
        if (!s.t.isBefore(edge.t)) break;
        prev = s;
      }
      bound = prev?.t ?? startedAt;
      if (bound.isAfter(edge.t)) return 0; // armed after first sample
    } else {
      for (final s in samples) {
        if (s.t.isAfter(edge.t)) {
          bound = s.t;
          break;
        }
      }
      bound ??= finishedAt;
      if (bound == null) return 0; // still running: edge is live, not lost
    }
    final gapH = (before
                ? edge.t.difference(bound)
                : bound.difference(edge.t))
            .inMilliseconds /
        3.6e6;
    return edge.amps.abs() * gapH / 2;
  }

  Map<String, dynamic> toJson() => {
        'config': config.toJson(),
        'startedAt': startedAt.toUtc().toIso8601String(),
        'finishedAt': finishedAt?.toUtc().toIso8601String(),
        'socStartPct': socStartPct,
        'socEndPct': socEndPct,
        'samples': samples.map((s) => s.toJson()).toList(),
      };

  factory CapacityTestSession.fromJson(Map<String, dynamic> j) {
    final s = CapacityTestSession(
      config: CapacityTestConfig.fromJson(j['config'] as Map<String, dynamic>),
      startedAt: DateTime.parse(j['startedAt'] as String),
    );
    final fin = j['finishedAt'] as String?;
    if (fin != null) s.finishedAt = DateTime.parse(fin);
    s.socStartPct = (j['socStartPct'] as num?)?.toDouble();
    s.socEndPct = (j['socEndPct'] as num?)?.toDouble();
    for (final e in j['samples'] as List) {
      final cs = CurrentSample.fromJson(e as Map<String, dynamic>);
      s.samples.add(cs);
    }
    return s;
  }

  String toJsonString() => jsonEncode(toJson());
  factory CapacityTestSession.fromJsonString(String s) =>
      CapacityTestSession.fromJson(jsonDecode(s) as Map<String, dynamic>);
}
