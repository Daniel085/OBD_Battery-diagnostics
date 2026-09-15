/// File-backed persistence for a recorded drive.
///
/// A drive report is worth keeping (a buyer shows it to a seller; an owner
/// compares over time), and the app can be backgrounded or killed mid-drive,
/// so the record is persisted incrementally and survives restarts. One JSON
/// file in the app documents directory; the engine's record serialises itself.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../engine/drive_record.dart';

class DriveRecordStore {
  final Future<File> Function() _resolve;

  DriveRecordStore(this._resolve);

  factory DriveRecordStore.documents() => DriveRecordStore(() async {
        final dir = await getApplicationDocumentsDirectory();
        return File('${dir.path}/drive_record.json');
      });

  factory DriveRecordStore.inDirectory(Directory dir) =>
      DriveRecordStore(() async => File('${dir.path}/drive_record.json'));

  Future<DriveRecord?> load() async {
    try {
      final f = await _resolve();
      if (!await f.exists()) return null;
      return DriveRecord.fromJsonString(await f.readAsString());
    } on FormatException {
      return null; // corrupt file: start fresh rather than crash forever
    } on IOException {
      return null;
    }
  }

  Future<void> save(DriveRecord record) async {
    final f = await _resolve();
    // Write-then-rename so a crash mid-write can't corrupt the only copy.
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(record.toJson()), flush: true);
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
