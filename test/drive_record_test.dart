import 'package:obd_battery_diagnostics/engine/drive_record.dart';
import 'package:test/test.dart';

DateTime t0 = DateTime.utc(2026, 9, 15, 15);
DateTime at(int s) => t0.add(Duration(seconds: s));

void main() {
  test('peaks, energy split, and regen fraction', () {
    final r = DriveRecord();
    // 30 s hard pull at +150 kW, then 30 s regen at -40 kW, 1 Hz.
    for (var s = 0; s <= 30; s++) {
      r.add(DriveTick(t: at(s), kw: 150, amps: 400, volts: 375));
    }
    for (var s = 31; s <= 60; s++) {
      r.add(DriveTick(t: at(s), kw: -40, amps: -110, volts: 400));
    }
    final sum = r.summarize();
    expect(sum.peakDrawKw, 150);
    expect(sum.peakRegenKw, 40);
    expect(sum.peakAmps, 400);
    // ~150 kW × 30 s, plus a sliver from the draw→regen crossing interval.
    expect(sum.energyUsedKwh, closeTo(150 * 30 / 3600, 0.02));
    expect(sum.energyRecoveredKwh, closeTo(40 * 29 / 3600, 0.02));
    expect(sum.regenFraction, closeTo(sum.energyRecoveredKwh / sum.energyUsedKwh, 1e-9));
  });

  test('voltage sag: min loaded voltage ignores unloaded/coasting ticks', () {
    final r = DriveRecord(loadThresholdAmps: 20);
    r.add(DriveTick(t: at(0), kw: 0, amps: 0, volts: 402));    // idle, low V ignored? no—unloaded
    r.add(DriveTick(t: at(1), kw: 60, amps: 160, volts: 388)); // loaded
    r.add(DriveTick(t: at(2), kw: 90, amps: 245, volts: 372)); // harder → lowest loaded
    r.add(DriveTick(t: at(3), kw: 0, amps: 2, volts: 360));    // coasting, V dip but UNLOADED
    final sum = r.summarize();
    // 360 V happened while unloaded (2 A) → must be ignored; 372 is the min under load.
    expect(sum.minLoadedVolts, 372);
    expect(sum.ampsAtMinVolts, 245);
  });

  test('no live voltage → sag fields null (Lyriq nominal-constant case)', () {
    final r = DriveRecord();
    for (var s = 0; s < 10; s++) {
      r.add(DriveTick(t: at(s), kw: 80, amps: 220)); // volts omitted
    }
    final sum = r.summarize();
    expect(sum.minLoadedVolts, isNull);
    expect(sum.ampsAtMinVolts, isNull);
    expect(sum.peakDrawKw, 80);
  });

  test('temperature rise across the drive', () {
    final r = DriveRecord();
    r.add(DriveTick(t: at(0), kw: 50, amps: 130, tempC: 24));
    r.add(DriveTick(t: at(60), kw: 50, amps: 130, tempC: 24));
    r.add(DriveTick(t: at(120), kw: 50, amps: 130, tempC: 27));
    final sum = r.summarize();
    expect(sum.tempStartC, 24);
    expect(sum.tempEndC, 27);
    expect(sum.tempRiseC, 3);
  });

  test('gaps beyond maxIntegrationGap excluded from energy', () {
    final r = DriveRecord(maxIntegrationGap: const Duration(seconds: 5));
    r.add(DriveTick(t: at(0), kw: 100, amps: 270));
    r.add(DriveTick(t: at(1), kw: 100, amps: 270));   // 1 s counted
    r.add(DriveTick(t: at(600), kw: 100, amps: 270)); // 10 min gap excluded
    r.add(DriveTick(t: at(601), kw: 100, amps: 270)); // 1 s counted
    final sum = r.summarize();
    expect(sum.energyUsedKwh, closeTo(100 * 2 / 3600, 1e-6));
  });

  test('report text renders the buyer-facing fields', () {
    final r = DriveRecord(vehicle: 'Cadillac Lyriq (2025)');
    r.add(DriveTick(t: at(0), kw: 0, amps: 0, tempC: 22));
    r.add(DriveTick(t: at(5), kw: 120, amps: 330, volts: 370, tempC: 22));
    r.add(DriveTick(t: at(10), kw: -30, amps: -80, volts: 398, tempC: 23));
    final txt = r.reportText();
    expect(txt, contains('EV Drive Health Report'));
    expect(txt, contains('Cadillac Lyriq'));
    expect(txt, contains('Peak power delivered: 120.0 kW'));
    expect(txt, contains('Min pack voltage under load: 370.0 V'));
    expect(txt, contains('Battery temp: 22 → 23'));
  });

  test('JSON round-trip preserves ticks and summary', () {
    final r = DriveRecord(vehicle: 'X');
    for (var s = 0; s < 20; s++) {
      r.add(DriveTick(t: at(s), kw: 40.0 + s, amps: 110.0 + s, volts: 390.0 - s));
    }
    r.finish();
    final back = DriveRecord.fromJsonString(r.toJsonString());
    expect(back.finished, isTrue);
    expect(back.ticks.length, r.ticks.length);
    expect(back.vehicle, 'X');
    expect(back.summarize().peakDrawKw, r.summarize().peakDrawKw);
    expect(back.summarize().energyUsedKwh,
        closeTo(r.summarize().energyUsedKwh, 1e-9));
    // finished records reject further ticks
    back.add(DriveTick(t: at(999), kw: 1, amps: 1));
    expect(back.ticks.length, r.ticks.length);
  });
}
