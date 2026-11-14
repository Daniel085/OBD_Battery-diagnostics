/// File-backed persistence for app settings (one JSON file in the app
/// documents directory), same pattern as the other stores.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../engine/display_units.dart';

class SettingsStore {
  final Future<File> Function() _resolve;

  SettingsStore(this._resolve);

  factory SettingsStore.documents() => SettingsStore(() async {
        final dir = await getApplicationDocumentsDirectory();
        return File('${dir.path}/settings.json');
      });

  factory SettingsStore.inDirectory(Directory dir) =>
      SettingsStore(() async => File('${dir.path}/settings.json'));

  /// The saved display units. Anything not saved (the whole file, or one
  /// setting added after the file was written) comes from [defaults].
  Future<DisplayUnits> loadUnits(
      {DisplayUnits defaults = const DisplayUnits()}) async {
    try {
      final f = await _resolve();
      if (!await f.exists()) return defaults;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map<String, dynamic>) return defaults;
      final units = j['units'];
      return units is Map<String, dynamic>
          ? DisplayUnits.fromJson(units, defaults: defaults)
          : defaults;
    } on FormatException {
      return defaults; // corrupt file: defaults, not a crash
    } on IOException {
      return defaults;
    }
  }

  Future<void> saveUnits(DisplayUnits units) async {
    final f = await _resolve();
    // Write-then-rename so a crash mid-write can't corrupt the only copy.
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode({'units': units.toJson()}), flush: true);
    await tmp.rename(f.path);
  }
}
