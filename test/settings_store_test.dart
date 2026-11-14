import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obd_battery_diagnostics/app/app_controller.dart';
import 'package:obd_battery_diagnostics/app/settings_store.dart';
import 'package:obd_battery_diagnostics/engine/display_units.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('settings'));
  tearDown(() => dir.deleteSync(recursive: true));

  const fahrenheit = DisplayUnits(temperature: TemperatureUnit.fahrenheit);

  test('defaults when nothing is saved; save/load round-trip', () async {
    final store = SettingsStore.inDirectory(dir);
    expect(await store.loadUnits(), const DisplayUnits());

    await store.saveUnits(fahrenheit);
    expect(await store.loadUnits(), fahrenheit);

    await store.saveUnits(const DisplayUnits());
    expect(await store.loadUnits(), const DisplayUnits());
  });

  test('a corrupt or wrong-shaped file loads as defaults', () async {
    final store = SettingsStore.inDirectory(dir);
    final file = File('${dir.path}/settings.json');
    for (final bad in ['{not json', '[1,2]', '{"units": 5}', '']) {
      file.writeAsStringSync(bad);
      expect(await store.loadUnits(), const DisplayUnits(), reason: bad);
    }
  });

  test('the controller persists the choice and restores it', () async {
    final first = AppController(settingsStore: SettingsStore.inDirectory(dir));
    await first.restoreSettings();
    expect(first.units.temperature, TemperatureUnit.celsius);

    var notified = 0;
    first.addListener(() => notified++);
    first.setTemperatureUnit(TemperatureUnit.fahrenheit);
    expect(first.units, fahrenheit);
    expect(notified, 1);
    first.setTemperatureUnit(TemperatureUnit.fahrenheit); // no change
    expect(notified, 1);

    // The save is fire-and-forget; wait for the file before "restarting".
    final file = File('${dir.path}/settings.json');
    for (var i = 0; i < 100 && !file.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    final second = AppController(settingsStore: SettingsStore.inDirectory(dir));
    await second.restoreSettings();
    expect(second.units, fahrenheit);
    first.dispose();
    second.dispose();
  });
}
