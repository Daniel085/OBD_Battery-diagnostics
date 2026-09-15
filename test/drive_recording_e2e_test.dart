import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:obd_battery_diagnostics/app/app_controller.dart';
import 'package:obd_battery_diagnostics/app/signal_set_repository.dart';
import 'package:obd_battery_diagnostics/engine/signal_set.dart';
import 'package:obd_battery_diagnostics/transport/simulated_source.dart';

class _Repo implements SignalSetRepository {
  final SignalSet set; _Repo(this.set);
  @override Future<SignalSet> load(VehicleEntry e) async => set;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('drive recording captures ticks end-to-end via the sim', () async {
    final set = SignalSet.parse(
        File('signalsets/Cadillac-Lyriq-2025/v01.json').readAsStringSync());
    final c = AppController(repository: _Repo(set));
    final lyriq = SignalSetRepository.catalogue
        .firstWhere((v) => v.id == 'Cadillac-Lyriq-2025');
    await c.connectWithSource(SimulatedLyriqSource(), lyriq);
    expect(c.startDriveRecording(), isTrue);
    expect(c.isRecordingDrive, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    c.finishDriveRecording();
    final rec = c.driveRecord!;
    expect(rec.ticks.length, greaterThan(3));
    final s = rec.summarize();
    // Sim "charges" at ~-22.75A -> regen side; peak regen ~8 kW, no draw.
    expect(s.peakRegenKw, greaterThan(5));
    expect(rec.reportText(), contains('EV Drive Health Report'));
    await c.disconnect(); c.dispose();
  });
}
