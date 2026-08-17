/// File-backed persistence for the capacity test session.
///
/// A capacity test spans a 5-10 h charge with the app connecting and
/// disconnecting many times (and likely being killed in between), so the
/// session must outlive the process. One JSON file in the app documents
/// directory; the engine's session serialises itself.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../engine/capacity_test.dart';

class CapacityTestStore {
  final Future<File> Function() _resolve;

  CapacityTestStore(this._resolve);

  /// The real app's store, in the platform documents directory.
  factory CapacityTestStore.documents() => CapacityTestStore(() async {
        final dir = await getApplicationDocumentsDirectory();
        return File('${dir.path}/capacity_test.json');
      });

  /// A store rooted in [dir] — for tests.
  factory CapacityTestStore.inDirectory(Directory dir) =>
      CapacityTestStore(() async => File('${dir.path}/capacity_test.json'));

  Future<CapacityTestSession?> load() async {
    try {
      final f = await _resolve();
      if (!await f.exists()) return null;
      return CapacityTestSession.fromJsonString(await f.readAsString());
    } on FormatException {
      return null; // corrupt file: start fresh rather than crash forever
    } on IOException {
      return null;
    }
  }

  Future<void> save(CapacityTestSession session) async {
    final f = await _resolve();
    // Write-then-rename so a crash mid-write can't corrupt the only copy.
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(session.toJson()), flush: true);
    await tmp.rename(f.path);
  }

  Future<void> clear() async {
    try {
      final f = await _resolve();
      if (await f.exists()) await f.delete();
    } on IOException {
      // Best-effort: an undeletable stale file is overwritten on next save.
    }
  }
}
