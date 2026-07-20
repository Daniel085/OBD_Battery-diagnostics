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

  @override
  Future<String> send(String command, {Duration? timeout}) async {
    if (_busy) concurrentViolations++;
    _busy = true;
    await Future<void>.delayed(const Duration(milliseconds: 15));
    _busy = false;
    final cmd = command.trim().toUpperCase();
    if (cmd.startsWith('AT')) return 'OK\r>';
    if (cmd == '0722DDBC') return '607 05 62 DD BC 03 20\r>';
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
        File('signalsets/BMW-330e-2018/v01.json').readAsStringSync());
    final source = _SlowSource();
    final controller = AppController(repository: _InMemoryRepo(set));
    controller.pollInterval = const Duration(milliseconds: 5);

    final bmw = SignalSetRepository.catalogue
        .firstWhere((v) => v.id == 'BMW-330e-2018');
    await controller.connectWithSource(source, bmw);

    // Each poll ~ 6 * 15 ms = 90 ms, far longer than the 5 ms interval.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await controller.disconnect();

    expect(source.concurrentViolations, 0,
        reason: 'overlapping polls issued concurrent commands');
    expect(controller.latest.containsKey('HVBAT_SOC'), isTrue);
    controller.dispose();
  });
}
