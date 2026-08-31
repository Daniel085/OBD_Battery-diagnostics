import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obd_battery_diagnostics/app/app_controller.dart';
import 'package:obd_battery_diagnostics/app/signal_set_repository.dart';
import 'package:obd_battery_diagnostics/engine/signal_set.dart';
import 'package:obd_battery_diagnostics/transport/simulated_source.dart';

class _InMemoryRepo implements SignalSetRepository {
  final SignalSet set;
  _InMemoryRepo(this.set);
  @override
  Future<SignalSet> load(VehicleEntry entry) async => set;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('drive mode fast-polls pack current and accumulates a session',
      () async {
    final set = SignalSet.parse(
        File('signalsets/Cadillac-Lyriq-2025/v01.json').readAsStringSync());
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
    expect(controller.latest.containsKey('HVBAT_TEMP_1'), isTrue,
        reason: 'normal polling should resume after drive mode');

    await controller.disconnect();
    controller.dispose();
  });

  test('drive mode refuses a vehicle without a pack-current signal', () async {
    // BMW set HAS a pack-current command; strip it to simulate a vehicle
    // without one.
    final full = SignalSet.parse(
        File('signalsets/BMW-330e-2018/v01.json').readAsStringSync());
    final json = File('signalsets/BMW-330e-2018/v01.json').readAsStringSync();
    final stripped = SignalSet.parse(json.replaceAll('HVBAT_CURRENT', 'X_NOPE'));
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
