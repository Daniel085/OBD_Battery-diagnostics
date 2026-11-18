import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obd_battery_diagnostics/app/app_controller.dart';
import 'package:obd_battery_diagnostics/app/signal_set_repository.dart';
import 'package:obd_battery_diagnostics/engine/signal_set.dart';
import 'package:obd_battery_diagnostics/transport/data_source.dart';

/// A source whose every response is delayed, so a poll cycle (6 sequential BMW
/// reads) reliably outlasts a short poll interval — exercising the re-entrancy
/// guard. It counts any moment two commands are in flight at once, exactly like
/// ElmBleSource would reject, so an overlapping poll shows up here.
class _SlowSource implements DataSource {
  bool _connected = false;
  bool _busy = false;
  int concurrentViolations = 0;

  @override
  String get name => 'Slow';
  @override
  bool get isConnected => _connected;
  @override
  Future<void> connect() async => _connected = true;
  @override
  Future<void> disconnect() async => _connected = false;

  final sent = <String>[];

  @override
  Future<String> send(String command, {Duration? timeout}) async {
    sent.add(command);
    if (_busy) concurrentViolations++;
    _busy = true;
    await Future<void>.delayed(const Duration(milliseconds: 15));
    _busy = false;
    final cmd = command.trim().toUpperCase();
    if (cmd.startsWith('AT')) return 'OK\r>';
    if (cmd == '22DDBC') {
      return '607 F1 10 09 62 DD BC 03 20\r607 F1 21 03 0C 00 F6 FF FF\r>';
    }
    return 'NO DATA\r>';
  }
}

/// Repository that returns a pre-parsed set, bypassing the Flutter asset bundle.
class _InMemoryRepo implements SignalSetRepository {
  final SignalSet set;
  _InMemoryRepo(this.set);
  @override
  Future<SignalSet> load(VehicleEntry entry) async => set;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('poll loop does not overlap even when a poll outlasts the interval',
      () async {
    final set = SignalSet.parse(
        File('signalsets/BMW-330e-2018/v02.json').readAsStringSync());
    final source = _SlowSource();
    final controller = AppController(repository: _InMemoryRepo(set));
    controller.pollInterval = const Duration(milliseconds: 5);

    final bmw = SignalSetRepository.catalogue
        .firstWhere((v) => v.id == 'BMW-330e-2018');
    await controller.connectWithSource(source, bmw);

    // A full BMW poll (init + J1979 PIDs + SME mode switch + DIDs) is ~40
    // commands * 15 ms, far longer than the 5 ms interval.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    await controller.disconnect();

    expect(source.concurrentViolations, 0,
        reason: 'overlapping polls issued concurrent commands');
    expect(controller.latest.containsKey('HVBAT_SOC'), isTrue);
    controller.dispose();
  });

  test('a tool that holds the adapter has it alone, then the poll resumes',
      () async {
    final set = SignalSet.parse(
        File('signalsets/BMW-330e-2018/v02.json').readAsStringSync());
    final source = _SlowSource();
    final controller = AppController(repository: _InMemoryRepo(set));
    controller.pollInterval = const Duration(milliseconds: 5);
    final bmw = SignalSetRepository.catalogue
        .firstWhere((v) => v.id == 'BMW-330e-2018');
    await controller.connectWithSource(source, bmw);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // What a terminal or scanner does: its own header, then requests, while
    // the poll timer keeps firing every 5 ms.
    late int from, to;
    await controller.withAdapter((adapter) async {
      expect(controller.adapterHeld, isTrue);
      from = source.sent.length;
      await adapter.send('ATSH7E4');
      for (var i = 0; i < 10; i++) {
        await adapter.send('224801');
      }
      to = source.sent.length;
    });
    expect(source.sent.sublist(from, to),
        ['ATSH7E4', ...List.filled(10, '224801')],
        reason: 'the poll sent commands while the tool had the adapter');
    expect(controller.adapterHeld, isFalse);

    // The poll comes back and does not trust the header the tool left: it
    // sets addressing and header again before its next request.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    await controller.disconnect();
    final after = source.sent.sublist(to);
    expect(after, contains('22DDBC'));
    expect(after.indexOf('ATSH6F1'), inInclusiveRange(0, after.indexOf('22DDBC')));
    expect(source.concurrentViolations, 0);
    controller.dispose();
  });
}
