import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obd_battery_diagnostics/app/app_controller.dart';
import 'package:obd_battery_diagnostics/app/signal_set_repository.dart';
import 'package:obd_battery_diagnostics/engine/signal_set.dart';
import 'package:obd_battery_diagnostics/transport/data_source.dart';
import 'package:obd_battery_diagnostics/transport/simulated_source.dart';

class _InMemoryRepo implements SignalSetRepository {
  final SignalSet set;
  _InMemoryRepo(this.set);
  @override
  Future<SignalSet> load(VehicleEntry entry) async => set;
}

/// A BMW whose motor ECU (3A) never answers.
class _NoMotorEcu implements DataSource {
  final DataSource inner;
  String _cea = '';
  int motorRequests = 0;
  _NoMotorEcu(this.inner);

  @override
  String get name => inner.name;
  @override
  bool get isConnected => inner.isConnected;
  @override
  Future<void> connect() => inner.connect();
  @override
  Future<void> disconnect() => inner.disconnect();
  @override
  Future<String> send(String command, {Duration? timeout}) async {
    if (command.startsWith('ATCEA')) _cea = command.substring(5);
    if (!command.startsWith('AT') && _cea == '3A') {
      motorRequests++;
      return 'NO DATA\r>';
    }
    return inner.send(command, timeout: timeout);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('drive mode fast-polls pack current and accumulates a session',
      () async {
    final set = SignalSet.parse(
        File('signalsets/Cadillac-Lyriq-2025/v02.json').readAsStringSync());
    final controller = AppController(repository: _InMemoryRepo(set));
    final lyriq = SignalSetRepository.catalogue
        .firstWhere((v) => v.id == 'Cadillac-Lyriq-2025');

    await controller.connectWithSource(SimulatedLyriqSource(), lyriq);
    expect(controller.startDriveMode(), isTrue);
    expect(controller.driveModeActive, isTrue);

    // The 50 ms poll floor gives ~20 Hz max; expect a healthy sample count.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final session = controller.driveSession!;
    expect(session.sampleCount, greaterThan(5));

    // Sim charges at ~-22.75 A × 352.09 V ≈ -8.0 kW: all regen, no draw.
    expect(session.currentKw, closeTo(-8.0, 0.5));
    expect(session.peakRegenKw, closeTo(8.0, 0.5));
    expect(session.peakDrawKw, 0);
    expect(session.energyRecoveredKwh, greaterThan(0));
    expect(session.energyUsedKwh, 0);

    // Stopping resumes the normal all-signals poll.
    controller.stopDriveMode();
    expect(controller.driveModeActive, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(controller.latest.containsKey('HVBAT_TEMP_3'), isTrue,
        reason: 'normal polling should resume after drive mode');

    await controller.disconnect();
    controller.dispose();
  });

  test('BMW drive mode: a running, stationary car is drawing, never regen',
      () async {
    // The SME's raw current sign is +charge; the signal set negates it to the
    // app's +discharge convention. The sim replays the real parked-running
    // read (raw -1.48 A): that is a small draw, and must not show as regen.
    final set = SignalSet.parse(
        File('signalsets/BMW-330e-2018/v02.json').readAsStringSync());
    final controller = AppController(repository: _InMemoryRepo(set));
    final bmw = SignalSetRepository.catalogue
        .firstWhere((v) => v.id == 'BMW-330e-2018');

    await controller.connectWithSource(SimulatedBmwSource(), bmw);
    expect(controller.startDriveMode(), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final session = controller.driveSession!;
    expect(session.sampleCount, greaterThan(5));

    // ~1.1-1.9 A x ~316 V: a few hundred watts out of the pack.
    expect(session.currentKw, inInclusiveRange(0.3, 0.65));
    expect(session.peakRegenKw, 0);
    expect(session.peakDrawKw, greaterThan(0));
    expect(session.energyRecoveredKwh, 0);
    expect(session.energyUsedKwh, greaterThan(0));

    await controller.disconnect();
    controller.dispose();
  });

  test('BMW drive mode also reads the motor signals, at a lower rate',
      () async {
    final set = SignalSet.parse(
        File('signalsets/BMW-330e-2018/v02.json').readAsStringSync());
    final controller = AppController(repository: _InMemoryRepo(set))
      ..driveExtrasSpacing = const Duration(milliseconds: 100);
    final bmw = SignalSetRepository.catalogue
        .firstWhere((v) => v.id == 'BMW-330e-2018');

    await controller.connectWithSource(SimulatedBmwSource(), bmw);
    expect(controller.hasDriveExtras, isTrue);
    // Start from a clean slate so the values below come from drive mode.
    controller.latest.removeWhere((id, _) => id.startsWith('MOTOR_'));
    expect(controller.startDriveMode(), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 700));

    final motor = {
      for (final r in controller.driveExtraReadings) r.signal.id: r.value
    };
    expect(motor.keys, [
      'MOTOR_TEMP_1',
      'MOTOR_TEMP_2',
      'MOTOR_RPM',
      'MOTOR_TORQUE',
      'MOTOR_TORQUE_TARGET',
    ]);
    expect(motor['MOTOR_TEMP_1'], closeTo(39.7, 0.2));
    expect(motor['MOTOR_TEMP_2'], closeTo(41.7, 0.2));
    expect(motor['MOTOR_RPM'], 0);
    expect(controller.driveExtrasResponding, isTrue);

    // The power feed keeps running between motor reads, and switching ECUs
    // back and forth does not corrupt it.
    final session = controller.driveSession!;
    expect(session.sampleCount, greaterThan(4));
    expect(session.currentKw, inInclusiveRange(0.3, 0.65));
    expect(session.peakRegenKw, 0);

    await controller.disconnect();
    controller.dispose();
  });

  test('motor reads that never answer are dropped; power keeps flowing',
      () async {
    final set = SignalSet.parse(
        File('signalsets/BMW-330e-2018/v02.json').readAsStringSync());
    final controller = AppController(repository: _InMemoryRepo(set))
      ..driveExtrasSpacing = const Duration(milliseconds: 50);
    final bmw = SignalSetRepository.catalogue
        .firstWhere((v) => v.id == 'BMW-330e-2018');
    final source = _NoMotorEcu(SimulatedBmwSource());

    await controller.connectWithSource(source, bmw);
    // Let the first full poll finish; count only drive mode's requests.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    source.motorRequests = 0;
    expect(controller.startDriveMode(), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 900));

    expect(controller.driveExtraReadings, isEmpty);
    expect(controller.driveExtrasResponding, isFalse);
    // Two commands, three tries each, then no more motor requests.
    expect(source.motorRequests, 6);
    expect(controller.driveSession!.sampleCount, greaterThan(4));
    expect(controller.driveModeActive, isTrue);

    await controller.disconnect();
    controller.dispose();
  });

  test('a vehicle without motor signals has no drive extras', () async {
    final set = SignalSet.parse(
        File('signalsets/Cadillac-Lyriq-2025/v02.json').readAsStringSync());
    final controller = AppController(repository: _InMemoryRepo(set));
    final lyriq = SignalSetRepository.catalogue
        .firstWhere((v) => v.id == 'Cadillac-Lyriq-2025');
    await controller.connectWithSource(SimulatedLyriqSource(), lyriq);
    expect(controller.hasDriveExtras, isFalse);
    expect(controller.driveExtraReadings, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await controller.disconnect();
    controller.dispose();
  });

  test('drive mode refuses a vehicle without a pack-current signal', () async {
    // BMW set HAS a pack-current command; strip it to simulate a vehicle
    // without one.
    final full = SignalSet.parse(
        File('signalsets/BMW-330e-2018/v02.json').readAsStringSync());
    final json = File('signalsets/BMW-330e-2018/v02.json').readAsStringSync();
    final stripped =
        SignalSet.parse(json.replaceAll('HVBAT_CURRENT', 'X_NOPE'));
    expect(full.signalsById.containsKey('HVBAT_CURRENT'), isTrue);

    final controller = AppController(repository: _InMemoryRepo(stripped));
    final bmw = SignalSetRepository.catalogue
        .firstWhere((v) => v.id == 'BMW-330e-2018');
    await controller.connectWithSource(SimulatedBmwSource(), bmw);

    expect(controller.startDriveMode(), isFalse);
    expect(controller.driveModeActive, isFalse);

    await controller.disconnect();
    controller.dispose();
  });
}
