import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obd_battery_diagnostics/app/app_controller.dart';
import 'package:obd_battery_diagnostics/app/signal_set_repository.dart';
import 'package:obd_battery_diagnostics/app/soh_history_store.dart';
import 'package:obd_battery_diagnostics/engine/signal_set.dart';
import 'package:obd_battery_diagnostics/engine/soh_history.dart';
import 'package:obd_battery_diagnostics/transport/simulated_source.dart';

SohEntry e(DateTime at, double soh,
        {SohSource source = SohSource.reported,
        String vehicle = 'BMW-330e-2018',
        double? odo}) =>
    SohEntry(
        at: at, vehicle: vehicle, source: source, sohPct: soh, odometerKm: odo);

class _InMemoryRepo implements SignalSetRepository {
  final SignalSet set;
  _InMemoryRepo(this.set);
  @override
  Future<SignalSet> load(VehicleEntry entry) async => set;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SohHistory.record', () {
    test('one entry per vehicle/source/day; steady value is not a change', () {
      final h = SohHistory();
      final d = DateTime(2026, 11, 8, 9);
      expect(h.record(e(d, 83)), isTrue);
      expect(h.record(e(d.add(const Duration(hours: 3)), 83)), isFalse);
      expect(h.entries, hasLength(1));
      // Same day, new value: replaces.
      expect(h.record(e(d.add(const Duration(hours: 4)), 82)), isTrue);
      expect(h.entries.single.sohPct, 82);
      // Next day: appends.
      expect(h.record(e(d.add(const Duration(days: 1)), 82)), isTrue);
      expect(h.entries, hasLength(2));
    });

    test('sources and vehicles are separate series', () {
      final h = SohHistory();
      final d = DateTime(2026, 11, 8);
      h.record(e(d, 83));
      h.record(e(d, 93, source: SohSource.bmsIndex));
      h.record(e(d, 99, vehicle: 'Cadillac-Lyriq-2025'));
      expect(h.series('BMW-330e-2018', SohSource.reported), hasLength(1));
      expect(h.series('BMW-330e-2018', SohSource.bmsIndex), hasLength(1));
      expect(h.series('Cadillac-Lyriq-2025', SohSource.reported), hasLength(1));
    });

    test('0 and >100 are "unavailable", never recorded', () {
      final h = SohHistory();
      expect(h.record(e(DateTime(2026), 0)), isFalse);
      expect(h.record(e(DateTime(2026), 101)), isFalse);
      expect(h.entries, isEmpty);
    });

    test('kept sorted by time even if recorded out of order', () {
      final h = SohHistory()
        ..record(e(DateTime(2026, 3, 1), 84))
        ..record(e(DateTime(2026, 1, 1), 85));
      expect(h.entries.first.at, DateTime(2026, 1, 1));
    });
  });

  group('SohHistory.trend', () {
    test('null until 3 entries spanning 30+ days', () {
      final h = SohHistory()
        ..record(e(DateTime(2026, 1, 1), 85))
        ..record(e(DateTime(2026, 1, 10), 85));
      expect(h.trend('BMW-330e-2018', SohSource.reported), isNull);
      h.record(e(DateTime(2026, 1, 20), 85));
      expect(h.trend('BMW-330e-2018', SohSource.reported), isNull); // 19 days
    });

    test('slope in % per year', () {
      final h = SohHistory()
        ..record(e(DateTime(2025, 1, 1), 86))
        ..record(e(DateTime(2025, 7, 2), 85))
        ..record(e(DateTime(2026, 1, 1), 84));
      final t = h.trend('BMW-330e-2018', SohSource.reported)!;
      expect(t.pctPerYear, closeTo(-2.0, 0.02));
      expect(t.spanDays, 365);
    });
  });

  test('JSON round trip keeps everything', () {
    final h = SohHistory()
      ..record(e(DateTime.utc(2026, 11, 8, 12), 83, odo: 77698))
      ..record(
          e(DateTime.utc(2026, 11, 8, 12), 93, source: SohSource.bmsIndex));
    final back = SohHistory.fromJsonString(h.toJsonString());
    expect(back.entries, hasLength(2));
    final r = back.series('BMW-330e-2018', SohSource.reported).single;
    expect(r.sohPct, 83);
    expect(r.odometerKm, 77698);
    expect(r.at, DateTime.utc(2026, 11, 8, 12));
  });

  group('SohHistoryStore', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('soh_store'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('missing file -> empty history; save/load round trip', () async {
      final store = SohHistoryStore.inDirectory(dir);
      expect((await store.load()).entries, isEmpty);
      await store.save(SohHistory()..record(e(DateTime(2026, 11, 8), 83)));
      expect((await store.load()).entries.single.sohPct, 83);
    });

    test('corrupt or wrong-shape file -> empty history, no crash', () async {
      final store = SohHistoryStore.inDirectory(dir);
      File('${dir.path}/soh_history.json').writeAsStringSync('{not json');
      expect((await store.load()).entries, isEmpty);
      File('${dir.path}/soh_history.json').writeAsStringSync('[1,2]');
      expect((await store.load()).entries, isEmpty);
    });
  });

  test('controller records reported SoH + odometer from a live poll', () async {
    final dir = Directory.systemTemp.createTempSync('soh_ctrl');
    addTearDown(() => dir.deleteSync(recursive: true));
    final set = SignalSet.parse(
        File('signalsets/BMW-330e-2018/v02.json').readAsStringSync());
    final store = SohHistoryStore.inDirectory(dir);
    final controller =
        AppController(repository: _InMemoryRepo(set), sohStore: store);
    final bmw = SignalSetRepository.catalogue
        .firstWhere((v) => v.id == 'BMW-330e-2018');
    await controller.connectWithSource(SimulatedBmwSource(), bmw);
    // Let the first poll finish.
    for (var i = 0; i < 50 && controller.latest['HVBAT_SOH'] == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await controller.disconnect();

    final s = controller.sohHistory.series('BMW-330e-2018', SohSource.reported);
    expect(s, hasLength(1));
    expect(s.single.sohPct, 83);
    expect(s.single.odometerKm, 77698);
    // Persisted.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect((await store.load()).entries, hasLength(1));
    controller.dispose();
  });

  group('readings and history stay with their own connection', () {
    Future<void> firstPoll(AppController c, String id) async {
      for (var i = 0; i < 100 && c.latest[id] == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(c.latest[id], isNotNull, reason: 'no $id reading');
    }

    final bmw = SignalSetRepository.catalogue
        .firstWhere((v) => v.id == 'BMW-330e-2018');
    final lyriq = SignalSetRepository.catalogue
        .firstWhere((v) => v.id == 'Cadillac-Lyriq-2025');

    test('a demo is shown but never written to the SoH history', () async {
      final controller = AppController();
      await controller.connectWithSource(SimulatedLyriqSource(), lyriq,
          demo: true);
      await firstPoll(controller, 'HVBAT_BMS_HEALTH_INDEX');
      expect(controller.isDemo, isTrue);
      expect(controller.latest['HVBAT_BMS_HEALTH_INDEX']!.value, 93);
      expect(controller.sohHistory.entries, isEmpty);
      await controller.disconnect();
      controller.dispose();
    });

    test('a second vehicle starts clean: no readings from the first',
        () async {
      // The 2026-11-13 bug: Lyriq demo, then the BMW in the same app run.
      // The Lyriq's BMS index (93) stayed in `latest` and was saved into the
      // BMW's history.
      final controller = AppController();
      await controller.connectWithSource(SimulatedLyriqSource(), lyriq,
          demo: true);
      await firstPoll(controller, 'HVBAT_BMS_HEALTH_INDEX');
      await controller.disconnect();

      await controller.connectWithSource(SimulatedBmwSource(), bmw);
      expect(controller.isDemo, isFalse);
      await firstPoll(controller, 'HVBAT_SOH');
      await controller.disconnect();

      expect(controller.latest.containsKey('HVBAT_BMS_HEALTH_INDEX'), isFalse);
      expect(controller.latest.containsKey('EVSE_PILOT_CURRENT'), isFalse);
      expect(
          controller.sohHistory.series('BMW-330e-2018', SohSource.bmsIndex),
          isEmpty);
      expect(
          controller.sohHistory.series('BMW-330e-2018', SohSource.reported),
          hasLength(1));
      expect(controller.sohHistory.entries, hasLength(1));
      // The BMW's signal set has no BMS index, so that source is not offered.
      expect(controller.sohSources,
          {SohSource.measured, SohSource.reported});
      controller.dispose();
    });
  });
}
