/// File-backed persistence for the SoH history (one JSON file in the app
/// documents directory), same pattern as the capacity-test and drive stores.
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../engine/soh_history.dart';

class SohHistoryStore {
  final Future<File> Function() _resolve;

  SohHistoryStore(this._resolve);

  factory SohHistoryStore.documents() => SohHistoryStore(() async {
        final dir = await getApplicationDocumentsDirectory();
        return File('${dir.path}/soh_history.json');
      });

  factory SohHistoryStore.inDirectory(Directory dir) =>
      SohHistoryStore(() async => File('${dir.path}/soh_history.json'));

  Future<SohHistory> load() async {
    try {
      final f = await _resolve();
      if (!await f.exists()) return SohHistory();
      return SohHistory.fromJsonString(await f.readAsString());
    } on FormatException {
      return SohHistory(); // corrupt file: start fresh rather than crash
    } on IOException {
      return SohHistory();
    } on TypeError {
      return SohHistory(); // valid JSON, wrong shape
    }
  }

  Future<void> save(SohHistory history) async {
    final f = await _resolve();
    // Write-then-rename so a crash mid-write can't corrupt the only copy.
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(history.toJsonString(), flush: true);
    await tmp.rename(f.path);
  }
}
