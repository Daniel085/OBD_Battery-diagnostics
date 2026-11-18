/// Captures kept on the phone: the raw record of each session with an
/// adapter, plus every signal-check report and DID sweep. They are written
/// as they happen, so a session with a vehicle we do not have at home comes
/// back complete even if nobody tapped "share" at the truck.
///
/// Plain text files in `captures/` under the app documents directory, named
/// `<date>-<time>_<vehicle>_<kind>.txt`, newest kept, oldest pruned.
library;

import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class CaptureStore {
  final Future<Directory> Function() _resolve;

  /// Oldest captures are deleted beyond these.
  final int maxFiles;
  final int maxBytes;

  CaptureStore(this._resolve,
      {this.maxFiles = 60, this.maxBytes = 80 * 1024 * 1024});

  factory CaptureStore.documents() => CaptureStore(() async {
        final dir = await getApplicationDocumentsDirectory();
        return Directory('${dir.path}/captures');
      });

  factory CaptureStore.inDirectory(Directory dir,
          {int maxFiles = 60, int maxBytes = 80 * 1024 * 1024}) =>
      CaptureStore(() async => dir, maxFiles: maxFiles, maxBytes: maxBytes);

  /// `20261116-140502_Ford-F-150-Hybrid-2021_session.txt`
  static String fileName(DateTime at, String vehicle, String kind) {
    String two(int n) => n.toString().padLeft(2, '0');
    final safe = vehicle.replaceAll(RegExp(r'[^A-Za-z0-9.-]+'), '-');
    return '${at.year}${two(at.month)}${two(at.day)}-'
        '${two(at.hour)}${two(at.minute)}${two(at.second)}_${safe}_$kind.txt';
  }

  Future<Directory> _dir() async {
    final dir = await _resolve();
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Start a capture that is written line by line (a session recording).
  Future<CaptureWriter> open(String name) async {
    final dir = await _dir();
    await prune(reserve: 1);
    return CaptureWriter._(File('${dir.path}/$name'));
  }

  /// Save a finished piece of text (a report, a sweep).
  Future<File> save(String name, String text) async {
    final dir = await _dir();
    final file = File('${dir.path}/$name');
    await file.writeAsString(text.endsWith('\n') ? text : '$text\n',
        flush: true);
    await prune();
    return file;
  }

  /// Captures on the phone, newest first (names start with the date).
  Future<List<File>> list() async {
    try {
      final dir = await _dir();
      final files = [
        await for (final e in dir.list())
          if (e is File && e.path.endsWith('.txt')) e
      ];
      files.sort((a, b) => b.path.compareTo(a.path));
      return files;
    } on IOException {
      return const [];
    }
  }

  Future<void> delete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on IOException {
      // Best-effort.
    }
  }

  /// Delete the oldest captures beyond [maxFiles] (less [reserve], to make
  /// room for one about to be created) or [maxBytes].
  Future<void> prune({int reserve = 0}) async {
    final files = await list();
    var kept = 0, bytes = 0;
    for (final f in files) {
      int size;
      try {
        size = await f.length();
      } on IOException {
        continue;
      }
      if (kept >= maxFiles - reserve || (kept > 0 && bytes + size > maxBytes)) {
        await delete(f);
      } else {
        kept++;
        bytes += size;
      }
    }
  }
}

/// Appends lines to one capture file. Lines are buffered and written to
/// disk every couple of seconds, so a killed app loses at most that much.
class CaptureWriter {
  final File file;
  final IOSink _sink;
  Timer? _flushTimer;
  bool _dirty = false;
  bool _closed = false;
  Future<void> _flushing = Future.value();

  CaptureWriter._(this.file)
      : _sink = file.openWrite(mode: FileMode.writeOnlyAppend) {
    _flushTimer = Timer.periodic(const Duration(seconds: 2), (_) => flush());
  }

  String get name => file.uri.pathSegments.last;

  void line(String text) {
    if (_closed) return;
    _sink.writeln(text);
    _dirty = true;
  }

  Future<void> flush() {
    if (!_dirty || _closed) return _flushing;
    _dirty = false;
    // IOSink allows one flush at a time.
    return _flushing = _flushing.then((_) => _sink.flush()).catchError((_) {});
  }

  Future<void> close() async {
    if (_closed) return;
    _flushTimer?.cancel();
    await flush();
    _closed = true;
    try {
      await _sink.close();
    } on IOException {
      // The lines already flushed are on disk; nothing more to do.
    }
  }
}
