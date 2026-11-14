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

  /// The saved display units, or the defaults if nothing usable is saved.
  Future<DisplayUnits> loadUnits() async {
    try {
      final f = await _resolve();
      if (!await f.exists()) return const DisplayUnits();
      final j = jsonDecode(await f.readAsString());
      if (j is! Map<String, dynamic>) return const DisplayUnits();
      final units = j['units'];
      return units is Map<String, dynamic>
          ? DisplayUnits.fromJson(units)
          : const DisplayUnits();
    } on FormatException {
      return const DisplayUnits(); // corrupt file: defaults, not a crash
    } on IOException {
      return const DisplayUnits();
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
