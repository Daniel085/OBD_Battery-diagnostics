/// Capturing a session on the phone alone: the recorder
/// (lib/transport/recording_source.dart), the capture files
/// (lib/app/capture_store.dart) and the controller that ties them to a
/// connection. The "truck" answers what OBDb captured on real F-150s.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obd_battery_diagnostics/app/app_controller.dart';
import 'package:obd_battery_diagnostics/app/capture_store.dart';
import 'package:obd_battery_diagnostics/app/signal_set_repository.dart';
import 'package:obd_battery_diagnostics/engine/diagnostics_client.dart';
import 'package:obd_battery_diagnostics/engine/signal_set.dart';
import 'package:obd_battery_diagnostics/tools/signal_check.dart';
import 'package:obd_battery_diagnostics/transport/data_source.dart';
import 'package:obd_battery_diagnostics/transport/recording_source.dart';
import 'package:obd_battery_diagnostics/transport/simulated_source.dart';

class _Truck extends ReplaySource {
  _Truck() : super(_script());

  static Map<String, String> _script() {
    final fixtures = jsonDecode(
        File('test/fixtures/obdb/Ford-F-150-Hybrid-2021.json')
            .readAsStringSync()) as Map<String, dynamic>;
    return {
      for (final c in (fixtures['cases'] as List).reversed)
        c['request'] as String: '${c['response']}\r>',
      '224801': '7EC 05 62 48 01 5A 3C\r>',
      '22490C': '7EC 03 7F 22 31\r>',
    };
  }

  @override
  Future<String> send(String command, {Duration? timeout}) async {
    if (command == '22480D') throw StateError('adapter fell over');
    final reply = await super.send(command, timeout: timeout);
    final isRequest = !command.toUpperCase().startsWith('AT');
    return isRequest && reply == '\r>' ? 'NO DATA\r>' : reply;
  }
}

class _Repo implements SignalSetRepository {
  final SignalSet set;
  _Repo(this.set);
  @override
  Future<SignalSet> load(VehicleEntry entry) async => set;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final set = SignalSet.parse(
      File('signalsets/Ford-F-150-Hybrid-2021/v01.json').readAsStringSync());
  final hybrid = SignalSetRepository.catalogue
      .firstWhere((v) => v.id == 'Ford-F-150-Hybrid-2021');
  late Directory dir;
  late CaptureStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('captures_test');
    store = CaptureStore.inDirectory(dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  group('RecordingSource', () {
    test('one line per exchange, replies on one line, errors marked', () async {
      final lines = <String>[];
      var tick = 0;
      final source = RecordingSource(_Truck(), lines.add,
          now: () => DateTime(2026, 11, 16, 9, 5, 7, 40 + tick++));
      await source.connect();
      await source.send('ATSH7E4');
      await source.send('224801');
      await source.send('22480B');
      await expectLater(source.send('22480D'), throwsStateError);
      expect(lines, [
        '09:05:07.040 ATSH7E4 -> ',
        '09:05:07.041 224801 -> 7EC 05 62 48 01 5A 3C',
        '09:05:07.042 22480B -> NO DATA',
        '09:05:07.043 22480D !! Bad state: adapter fell over',
      ]);
    });

    test('a recording gives back each exchange with its addressing', () {
      final exchanges = Recording.parse([
        '# Session capture',
        Recording.formatNote,
        '09:05:07.000 ATZ -> ELM327 v2.2',
        '09:05:07.100 0100 -> 7E8 06 41 00 BE 3F A8 13',
        '09:05:07.200 ATSH7E4 -> OK',
        '09:05:07.300 ATCRA7EC -> OK',
        '# 09:05:07.350 signal check started',
        '09:05:07.400 224801 -> 7EC 05 62 48 01 5A 3C',
        '09:05:07.500 ATCEA07 -> OK',
        '09:05:07.600 22DDBC -> 607 F1 10 09 62 DD BC 03 | 607 F1 21 03 0C',
        '09:05:07.700 ATCEA -> OK',
        '09:05:07.800 22480D !! TimeoutException after 0:00:05.000000',
        '',
      ].join('\n'));
      expect(exchanges, hasLength(9));
      expect(exchanges[1].hdr, isNull);
      expect(exchanges[1].isAdapterCommand, isFalse);
      final soc = exchanges[4];
      expect((soc.command, soc.hdr, soc.rax, soc.eax),
          ('224801', '7E4', '7EC', null));
      expect(soc.response, '7EC 05 62 48 01 5A 3C\r>');
      final bmw = exchanges[6];
      expect(bmw.eax, '07');
      expect(bmw.response, '607 F1 10 09 62 DD BC 03\r607 F1 21 03 0C\r>');
      final failed = exchanges[8];
      expect(failed.eax, isNull);
      expect(failed.reply, isNull);
      expect(failed.error, startsWith('TimeoutException'));
    });
  });

  group('CaptureStore', () {
    test('names sort by time and say what they are', () {
      expect(
          CaptureStore.fileName(DateTime(2026, 11, 6, 9, 5, 7),
              'Ford F-150/Hybrid 2021', 'check'),
          '20261106-090507_Ford-F-150-Hybrid-2021_check.txt');
    });

    test('lists newest first and prunes the oldest', () async {
      final small = CaptureStore.inDirectory(dir, maxFiles: 3);
      for (var day = 1; day <= 5; day++) {
        await small.save(
            CaptureStore.fileName(DateTime(2026, 11, day), 'car', 'check'),
            'report $day');
      }
      final names = [
        for (final f in await small.list()) f.uri.pathSegments.last
      ];
      expect(names, [
        '20261105-000000_car_check.txt',
        '20261104-000000_car_check.txt',
        '20261103-000000_car_check.txt',
      ]);
      expect((await small.list()).first.readAsStringSync(), 'report 5\n');
    });

    test('a size limit keeps at least the newest capture', () async {
      final tiny = CaptureStore.inDirectory(dir, maxBytes: 10);
      await tiny.save('20261101-000000_car_scan.txt', 'x' * 100);
      await tiny.save('20261102-000000_car_scan.txt', 'y' * 100);
      expect([for (final f in await tiny.list()) f.uri.pathSegments.last],
          ['20261102-000000_car_scan.txt']);
    });

    test('a writer appends lines and survives being closed twice', () async {
      final writer = await store.open('20261101-000000_car_session.txt');
      writer
        ..line('one')
        ..line('two');
      await writer.flush();
      expect(writer.file.readAsStringSync(), 'one\ntwo\n');
      writer.line('three');
      await writer.close();
      await writer.close();
      writer.line('ignored');
      expect(writer.file.readAsStringSync(), 'one\ntwo\nthree\n');
    });
  });

  group('a session on the truck, phone only', () {
    late AppController controller;
    late List<bool> awake;

    setUp(() {
      awake = [];
      controller = AppController(
          repository: _Repo(set), captureStore: store, keepAwake: awake.add);
      controller.pollInterval = const Duration(milliseconds: 20);
    });
    tearDown(() => controller.dispose());

    Future<String> session() async {
      final file = (await store.list())
          .singleWhere((f) => f.path.endsWith('_session.txt'));
      return file.readAsString();
    }

    test('everything is recorded without anyone asking, and replays', () async {
      await controller.connectWithSource(_Truck(), hybrid);
      expect(controller.recordingName, endsWith('_${set.vehicle}_session.txt'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final shown = {
        for (final e in controller.latest.entries) e.key: e.value.value
      };
      expect(shown['HVBAT_SOC'], isNotNull);
      expect(shown['LVBAT_SOC'], 53);
      await controller.disconnect();
      expect(controller.recordingName, isNull);
      expect(awake, [true, false]);

      final text = await session();
      expect(text, startsWith('# Session capture'));
      expect(text, contains('# vehicle: ${set.vehicle}'));
      expect(text, contains('# adapter: ReplaySource'));
      expect(text, contains(Recording.formatNote));

      final exchanges = Recording.parse(text);
      // The adapter set-up is there, then requests with their addressing.
      expect(exchanges.first.command, 'ATZ');
      final soc = exchanges.firstWhere((e) => e.command == '224801');
      expect((soc.hdr, soc.rax), ('7E4', '7EC'));
      expect(exchanges.where((e) => e.command == '22490C').first.reply,
          '7EC 03 7F 22 31');
      expect(exchanges.where((e) => e.command == '22480D').first.error,
          contains('adapter fell over'));

      // Home again: the recording alone gives the values the phone showed.
      final replay = ReplaySource({
        for (final e in exchanges)
          if (!e.isAdapterCommand && e.reply != null) e.command: e.response
      });
      await replay.connect();
      final again = await DiagnosticsClient(replay, set).readAll();
      expect({for (final e in again.entries) e.key: e.value.value}, shown);
    });

    test('tools are in the recording too, with notes, and reports are saved',
        () async {
      await controller.connectWithSource(_Truck(), hybrid);
      controller.captureNote('signal check started');
      final checks =
          await controller.withAdapter((s) => SignalCheck.run(s, set));
      final name = await controller.saveCapture(
          'check', SignalCheck.report(checks, set: set, when: DateTime(2026)));
      expect(name, endsWith('_${set.vehicle}_check.txt'));
      await controller.disconnect();

      final saved = (await store.list())
          .singleWhere((f) => f.path.endsWith('_check.txt'));
      expect(SignalCheck.repliesIn(saved.readAsStringSync()),
          hasLength(set.commands.length));
      final text = await session();
      expect(text,
          contains(RegExp(r'# \d\d:\d\d:\d\d\.\d\d\d signal check started')));
      expect(text, contains('saved $name'));
    });

    test('a demo session leaves nothing behind', () async {
      final bmw = SignalSetRepository.catalogue
          .firstWhere((v) => v.id == 'BMW-330e-2018');
      final demo = AppController(
          repository: _Repo(SignalSet.parse(
              File('signalsets/BMW-330e-2018/v02.json').readAsStringSync())),
          captureStore: store);
      await demo.connectWithSource(SimulatedBmwSource(), bmw, demo: true);
      expect(demo.recordingName, isNull);
      expect(await demo.saveCapture('check', 'report'), isNull);
      await demo.disconnect();
      demo.dispose();
      expect(await store.list(), isEmpty);
    });
  });
}
