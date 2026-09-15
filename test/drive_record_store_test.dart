import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obd_battery_diagnostics/app/drive_record_store.dart';
import 'package:obd_battery_diagnostics/engine/drive_record.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('driverec'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('save/load round-trip', () async {
    final store = DriveRecordStore.inDirectory(dir);
    expect(await store.load(), isNull);

    final r = DriveRecord(vehicle: 'Cadillac Lyriq (2025)');
    r.add(DriveTick(
        t: DateTime.utc(2026, 9, 15, 15), kw: 90, amps: 250, volts: 372, tempC: 24));
    await store.save(r);

    final back = await store.load();
    expect(back, isNotNull);
    expect(back!.vehicle, 'Cadillac Lyriq (2025)');
    expect(back.ticks.single.amps, 250);
    expect(back.summarize().peakDrawKw, 90);

    await store.clear();
    expect(await store.load(), isNull);
  });

  test('corrupt file loads as null instead of crashing', () async {
    final store = DriveRecordStore.inDirectory(dir);
    File('${dir.path}/drive_record.json').writeAsStringSync('{bad json');
    expect(await store.load(), isNull);
  });
}
