/// Drive-mode power telemetry: a rolling live-power session built from
/// fast-polled pack current × pack voltage.
///
/// Sign convention follows the pack-current signal (ECU 17 `2414`):
/// positive = discharge (power draw), negative = charge (regen). Power is
/// tracked in kW; energy integrals split draw vs regen so a drive shows
/// "used X kWh, recovered Y kWh".
///
/// Pure Dart, no Flutter imports.
library;

class PowerSample {
  final DateTime t;

  /// Kilowatts. Positive = drawing from the pack, negative = regen into it.
  final double kw;
  const PowerSample(this.t, this.kw);
}

class DriveSession {
  /// Samples newer than this window are kept for the live graph.
  final Duration window;

  /// Gaps longer than this are excluded from the energy integrals (app
  /// backgrounded / adapter dropout) — power between them is unknown.
  final Duration maxIntegrationGap;

  DriveSession({
    this.window = const Duration(seconds: 60),
    this.maxIntegrationGap = const Duration(seconds: 5),
  });

  final List<PowerSample> recent = [];

  DateTime? startedAt;
  DateTime? _lastT;
  double? _lastKw;
  int sampleCount = 0;

  double peakDrawKw = 0;
  double peakRegenKw = 0;
  double energyUsedKwh = 0;
  double energyRecoveredKwh = 0;

  void addSample(DateTime t, double kw) {
    startedAt ??= t;
    sampleCount++;
    if (kw > peakDrawKw) peakDrawKw = kw;
    if (-kw > peakRegenKw) peakRegenKw = -kw;

    final lastT = _lastT;
    if (lastT != null && t.isAfter(lastT)) {
      final gap = t.difference(lastT);
      if (gap <= maxIntegrationGap) {
        final dtH = gap.inMilliseconds / 3.6e6;
        final avg = (kw + _lastKw!) / 2;
        if (avg >= 0) {
          energyUsedKwh += avg * dtH;
        } else {
          energyRecoveredKwh += -avg * dtH;
        }
      }
    }
    _lastT = t;
    _lastKw = kw;

    recent.add(PowerSample(t, kw));
    final cutoff = t.subtract(window);
    while (recent.isNotEmpty && recent.first.t.isBefore(cutoff)) {
      recent.removeAt(0);
    }
  }

  /// Latest power reading, or null before the first sample.
  double? get currentKw => _lastKw;

  Duration get duration =>
      startedAt == null ? Duration.zero : _lastT!.difference(startedAt!);

  /// Achieved sample rate over the rolling window (the on-car answer to
  /// "how fast can this adapter actually poll").
  double get sampleRateHz {
    if (recent.length < 2) return 0;
    final spanMs =
        recent.last.t.difference(recent.first.t).inMilliseconds;
    if (spanMs <= 0) return 0;
    return (recent.length - 1) * 1000 / spanMs;
  }

  void reset() {
    recent.clear();
    startedAt = null;
    _lastT = null;
    _lastKw = null;
    sampleCount = 0;
    peakDrawKw = 0;
    peakRegenKw = 0;
    energyUsedKwh = 0;
    energyRecoveredKwh = 0;
  }
}
