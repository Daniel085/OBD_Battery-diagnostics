import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obd_battery_diagnostics/app/capacity_test_store.dart';
import 'package:obd_battery_diagnostics/engine/capacity_test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('captest'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('save/load round-trip', () async {
    final store = CapacityTestStore.inDirectory(dir);
    expect(await store.load(), isNull);

    final s = CapacityTestSession(startedAt: DateTime.utc(2026, 8, 17))
      ..socStartPct = 55;
    s.addSample(DateTime.utc(2026, 8, 17, 0, 1), -22.5);
    await store.save(s);

    final restored = await store.load();
    expect(restored, isNotNull);
    expect(restored!.socStartPct, 55);
    expect(restored.samples.single.amps, -22.5);

    await store.clear();
    expect(await store.load(), isNull);
  });

  test('corrupt file loads as null instead of crashing', () async {
    final store = CapacityTestStore.inDirectory(dir);
    File('${dir.path}/capacity_test.json').writeAsStringSync('{not json');
    expect(await store.load(), isNull);
  });
}
