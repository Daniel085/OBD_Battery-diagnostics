import 'package:obd_battery_diagnostics/engine/drive_session.dart';
import 'package:test/test.dart';

DateTime t0 = DateTime.utc(2026, 8, 22, 10);
DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

void main() {
  test('peaks and split energy integrals (draw vs regen)', () {
    final s = DriveSession();
    // 10 s at +100 kW draw, then 10 s at -40 kW regen, 10 Hz.
    for (var ms = 0; ms <= 10000; ms += 100) {
      s.addSample(at(ms), 100);
    }
    for (var ms = 10100; ms <= 20000; ms += 100) {
      s.addSample(at(ms), -40);
    }
    expect(s.peakDrawKw, 100);
    expect(s.peakRegenKw, 40);
    // 100 kW × 10 s = 0.278 kWh (plus half of the one crossing interval).
    expect(s.energyUsedKwh, closeTo(100 * 10 / 3600, 0.002));
    expect(s.energyRecoveredKwh, closeTo(40 * 9.9 / 3600, 0.005));
    expect(s.currentKw, -40);
    expect(s.duration, const Duration(seconds: 20));
    expect(s.sampleRateHz, closeTo(10, 0.5));
  });

  test('gaps beyond maxIntegrationGap are excluded from energy', () {
    final s = DriveSession();
    s.addSample(at(0), 50);
    s.addSample(at(1000), 50); // 1 s counted
    s.addSample(at(61000), 50); // 60 s gap: excluded
    s.addSample(at(62000), 50); // 1 s counted
    expect(s.energyUsedKwh, closeTo(50 * 2 / 3600, 1e-6));
  });

  test('rolling window trims old samples but stats persist', () {
    final s = DriveSession(window: const Duration(seconds: 10));
    for (var ms = 0; ms <= 30000; ms += 500) {
      s.addSample(at(ms), 80);
    }
    expect(s.recent.first.t.isAfter(at(19000)), isTrue);
    expect(s.sampleCount, 61);
    expect(s.energyUsedKwh, closeTo(80 * 30 / 3600, 0.01));
  });

  test('reset clears everything', () {
    final s = DriveSession();
    s.addSample(at(0), 100);
    s.addSample(at(100), -50);
    s.reset();
    expect(s.sampleCount, 0);
    expect(s.recent, isEmpty);
    expect(s.currentKw, isNull);
    expect(s.peakDrawKw, 0);
    expect(s.energyRecoveredKwh, 0);
    expect(s.duration, Duration.zero);
  });
}
