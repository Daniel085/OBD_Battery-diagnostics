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

  const us = DisplayUnits(
      temperature: TemperatureUnit.fahrenheit, distance: DistanceUnit.miles);

  test('region defaults fill in whatever is not saved', () async {
    final store = SettingsStore.inDirectory(dir);
    final file = File('${dir.path}/settings.json');
    // Nothing saved, or nothing usable: the defaults as given.
    expect(await store.loadUnits(defaults: us), us);
    file.writeAsStringSync('{not json');
    expect(await store.loadUnits(defaults: us), us);
    // A file from before the distance setting: temperature kept, distance
    // from the defaults.
    file.writeAsStringSync('{"units": {"temperature": "celsius"}}');
    expect(await store.loadUnits(defaults: us),
        const DisplayUnits(distance: DistanceUnit.miles));
    // A full saved choice beats the defaults.
    await store.saveUnits(const DisplayUnits());
    expect(await store.loadUnits(defaults: us), const DisplayUnits());
  });

  test('the controller starts on its region defaults and saves both units',
      () async {
    final first = AppController(
        settingsStore: SettingsStore.inDirectory(dir), defaultUnits: us);
    expect(first.units, us); // before anything is loaded
    await first.restoreSettings();
    expect(first.units, us);

    first.setDistanceUnit(DistanceUnit.kilometers);
    expect(first.units,
        const DisplayUnits(temperature: TemperatureUnit.fahrenheit));
    final file = File('${dir.path}/settings.json');
    for (var i = 0; i < 100 && !file.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    // A later launch in a different region keeps the saved choice.
    final second = AppController(
        settingsStore: SettingsStore.inDirectory(dir),
        defaultUnits: const DisplayUnits());
    await second.restoreSettings();
    expect(second.units,
        const DisplayUnits(temperature: TemperatureUnit.fahrenheit));
    first.dispose();
    second.dispose();
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
