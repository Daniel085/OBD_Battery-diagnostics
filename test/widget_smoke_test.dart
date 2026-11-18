import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:obd_battery_diagnostics/app/app_controller.dart';
import 'package:obd_battery_diagnostics/app/signal_set_repository.dart';
import 'package:obd_battery_diagnostics/engine/diagnostics_client.dart';
import 'package:obd_battery_diagnostics/engine/display_units.dart';
import 'package:obd_battery_diagnostics/engine/signal_set.dart';
import 'package:obd_battery_diagnostics/engine/soh_history.dart';
import 'package:obd_battery_diagnostics/ui/battery_visuals.dart';
import 'package:obd_battery_diagnostics/transport/data_source.dart';
import 'package:obd_battery_diagnostics/transport/simulated_source.dart';
import 'package:obd_battery_diagnostics/ui/dashboard_screen.dart';
import 'package:obd_battery_diagnostics/ui/drive_screen.dart';
import 'package:obd_battery_diagnostics/ui/home_screen.dart';
import 'package:obd_battery_diagnostics/ui/settings_screen.dart';
import 'package:obd_battery_diagnostics/ui/signal_check_screen.dart';

// Compiling this file forces the whole UI tree (home/dashboard/report screens,
// the PDF renderer, and the BLE-source imports) through the compiler, catching
// integration errors that pure-Dart tests miss. We construct the controller
// without touching real BLE (no scan is started), so it is device-independent.
class _FixedRepo implements SignalSetRepository {
  final SignalSet set;
  _FixedRepo(this.set);
  @override
  Future<SignalSet> load(VehicleEntry entry) async => set;
}

void main() {
  testWidgets('home screen renders with vehicle catalogue', (tester) async {
    final controller = AppController();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );

    expect(find.text('OBD Battery Diagnostics'), findsOneWidget);
    expect(find.text('1. Select vehicle'), findsOneWidget);
    for (final v in SignalSetRepository.catalogue) {
      expect(find.text(v.displayName), findsOneWidget);
    }
    controller.dispose();
  });

  testWidgets('onboarding shows first, Skip lands on home', (tester) async {
    final controller = AppController()..showOnboarding = true;
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );

    expect(find.text("See your EV battery's real data"), findsOneWidget);
    expect(find.text('1. Select vehicle'), findsNothing);

    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(find.text('1. Select vehicle'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('dashboard renders hero hierarchy from simulated Lyriq data',
      (tester) async {
    // Decode real readings through the full pipeline, then hand them to the
    // dashboard as the controller's latest snapshot.
    final set = SignalSet.parse(
        File('signalsets/Cadillac-Lyriq-2025/v02.json').readAsStringSync());
    final source = SimulatedLyriqSource();
    await source.connect();
    final client = DiagnosticsClient(source, set);
    await client.initialize();
    final readings = await client.readAll();

    final controller = AppController();
    controller.latest.addAll(readings);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: DashboardScreen()),
      ),
    );

    // Hero cards present, with the charging state derived from pack current.
    expect(find.text('Pack current'), findsOneWidget);
    expect(find.text('State of health'), findsOneWidget);
    expect(find.text('run a capacity test'), findsOneWidget);
    expect(find.text('Battery temps'), findsOneWidget);
    expect(find.textContaining('Charging'), findsOneWidget);
    // Demoted signals render as sections, not heroes. DYNAMICS sits below
    // the test viewport's fold, so scroll it into view first.
    // Module voltages collapse into one spread row in Cell balance.
    await tester.scrollUntilVisible(
        find.text('Module voltage (unverified)'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Module voltage (unverified)'), findsOneWidget);
    expect(find.text('3 readings'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('DYNAMICS'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('DYNAMICS'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('dashboard shows BMS SOH alongside measured, and never 0%',
      (tester) async {
    final set = SignalSet.parse(
        File('signalsets/Cadillac-Lyriq-2025/v02.json').readAsStringSync());
    final source = SimulatedLyriqSource();
    await source.connect();
    final client = DiagnosticsClient(source, set);
    await client.initialize();
    final readings = await client.readAll();

    final controller = AppController();
    controller.latest.addAll(readings);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: DashboardScreen()),
      ),
    );

    // Both health cards present and distinctly labeled — never merged.
    expect(find.text('BMS health index'), findsOneWidget);
    expect(find.text('93 %'), findsOneWidget);
    expect(find.text('451D · unverified as SOH'), findsOneWidget);
    // No capacity test has run, so the measured card prompts for one.
    expect(find.text('State of health'), findsOneWidget);
    expect(find.text('run a capacity test'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('BMS SOH of 0 renders as unavailable, not 0% healthy',
      (tester) async {
    // 0 means sparse mode / not yet converged — showing "0 %" would read as a
    // dead battery. Must degrade to a dash.
    final set = SignalSet.parse(
        File('signalsets/Cadillac-Lyriq-2025/v02.json').readAsStringSync());
    final sohSignal = set.signalsById['HVBAT_BMS_HEALTH_INDEX']!;
    final controller = AppController();
    controller.latest['HVBAT_BMS_HEALTH_INDEX'] =
        Reading(sohSignal, 0, DateTime.now());
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: DashboardScreen()),
      ),
    );
    expect(find.text('BMS health index'), findsOneWidget);
    expect(find.text('available with vehicle on'), findsOneWidget);
    expect(find.text('0 %'), findsNothing);
    controller.dispose();
  });

  testWidgets('BMW dashboard: charge ring, spread rows, SoH history',
      (tester) async {
    final set = SignalSet.parse(
        File('signalsets/BMW-330e-2018/v02.json').readAsStringSync());
    final source = SimulatedBmwSource();
    await source.connect();
    final client = DiagnosticsClient(source, set);
    await client.initialize();
    final readings = await client.readAll();

    final controller = AppController();
    controller.selectedVehicle = SignalSetRepository.catalogue
        .firstWhere((v) => v.id == 'BMW-330e-2018');
    controller.latest.addAll(readings);
    // Two prior days of history -> the chart renders.
    for (final (d, v) in [
      (DateTime(2026, 10, 1), 84.0),
      (DateTime(2026, 11, 1), 83.0)
    ]) {
      controller.sohHistory.record(SohEntry(
          at: d,
          vehicle: 'BMW-330e-2018',
          source: SohSource.reported,
          sohPct: v));
    }

    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: DashboardScreen()),
      ),
    );

    // Pack card: ring + current/power/voltage + window explanation.
    expect(find.byType(ChargeRing), findsOneWidget);
    expect(find.text('Pack voltage'), findsOneWidget);
    expect(find.text('Power'), findsOneWidget);
    expect(find.textContaining('Outer ring: the car uses 25–78 %'),
        findsOneWidget);
    // Health: reported SoH + history chart.
    expect(find.text('83 %'), findsOneWidget);
    expect(find.byType(SohHistoryChart), findsOneWidget);
    // Balance: the three min/avg/max families as spread rows; cell temps take
    // the place of the generic battery-temp row; oil/ambient stay in the list.
    await tester.scrollUntilVisible(find.text('Cell balance'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.byType(SpreadRow), findsNWidgets(3));
    expect(find.text('Cell voltage'), findsOneWidget);
    expect(find.text('Cell SoC'), findsOneWidget);
    expect(find.text('Cell temperature'), findsOneWidget);
    expect(find.textContaining('spread 9 mV'), findsOneWidget);
    expect(find.text('Battery temps'), findsNothing);
    // The sim idles at ~1.5 A: near rest, so the spread IS graded.
    expect(find.text('Under load: spread not graded'), findsNothing);
    controller.dispose();
  });

  testWidgets('BMW under load: cell-voltage spread shown but not graded',
      (tester) async {
    Reading r(String id, String name, String group, String unit, double v) =>
        Reading(
            Signal(
                id: id,
                name: name,
                group: group,
                fmt: SignalFormat(len: 16, unit: unit)),
            v,
            DateTime.now());
    Map<String, Reading> pack(double amps) => {
          // The 2026-11-14 read in Drive: 79 mV spread at 12.5 A.
          'HVBAT_CURRENT': r('HVBAT_CURRENT', 'Pack current', 'summary',
              'amps', amps),
          'HVBAT_CELL_V_MIN': r('HVBAT_CELL_V_MIN',
              'HV battery cell voltage (min)', 'cells', 'volts', 3.473),
          'HVBAT_CELL_V_AVG': r('HVBAT_CELL_V_AVG',
              'HV battery cell voltage (avg)', 'cells', 'volts', 3.522),
          'HVBAT_CELL_V_MAX': r('HVBAT_CELL_V_MAX',
              'HV battery cell voltage (max)', 'cells', 'volts', 3.552),
        };
    final controller = AppController();
    controller.latest.addAll(pack(12.5));
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: DashboardScreen()),
      ),
    );
    Color chip() => tester
        .widget<Text>(find.textContaining('spread 79 mV'))
        .style!
        .color!;
    final scheme = Theme.of(tester.element(find.byType(DashboardScreen)))
        .colorScheme;

    expect(find.text('Under load: spread not graded'), findsOneWidget);
    expect(chip(), scheme.onSurfaceVariant); // neutral, no verdict

    // The same spread at rest is graded, and 79 mV is past the limit.
    controller.latest.addAll(pack(0.5));
    controller.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Under load: spread not graded'), findsNothing);
    expect(chip(), scheme.error);
    controller.dispose();
  });

  testWidgets('BMW dashboard: computed cycle count, named values, durations',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 9000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final set = SignalSet.parse(
        File('signalsets/BMW-330e-2018/v02.json').readAsStringSync());
    final bmw = SignalSetRepository.catalogue
        .firstWhere((v) => v.id == 'BMW-330e-2018');
    final controller = AppController(repository: _FixedRepo(set));
    await tester.runAsync(() async {
      await controller.connectWithSource(SimulatedBmwSource(), bmw);
      for (var i = 0;
          i < 200 && controller.latest['HVBAT_MODULE_5_DEFECT'] == null;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await controller.disconnect();
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: DashboardScreen()),
      ),
    );
    await tester.pump();

    // 34,049 Ah in / rated 26 Ah, and a line saying where it comes from.
    expect(controller.equivalentFullCycles!.cycles.round(), 1310);
    expect(find.text('Equivalent full cycles'), findsOneWidget);
    expect(find.text('1310'), findsOneWidget);
    expect(find.textContaining('Computed by the app, not read from the car'),
        findsOneWidget);
    expect(find.textContaining('lifetime charge in ÷ rated 26.0 Ah'),
        findsOneWidget);
    // Module status 0 is shown by name; hours as years.
    expect(find.text('OK'), findsNWidgets(5));
    expect(find.text('8.9 years'), findsOneWidget);
    expect(find.text('1.2 years'), findsOneWidget);
  });

  testWidgets('imported Ford Lightning: dashboard from OBDb\'s captured replies',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 14000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final set = SignalSet.parse(
        File('signalsets/Ford-F-150-Lightning-2022/v01.json')
            .readAsStringSync());
    final entry = SignalSetRepository.catalogue
        .firstWhere((v) => v.id == 'Ford-F-150-Lightning-2022');
    // One captured reply per request (the last of each, usually a truck in
    // use rather than at 0 %).
    final fx = jsonDecode(
        File('test/fixtures/obdb/Ford-F-150-Lightning-2022.json')
            .readAsStringSync()) as Map<String, dynamic>;
    final replies = <String, String>{
      for (final c in (fx['cases'] as List).cast<Map<String, dynamic>>())
        c['request'] as String: '${c['response']}\r>',
    };
    expect(replies.length, set.commands.length); // no request used twice
    final controller = AppController(repository: _FixedRepo(set));
    await tester.runAsync(() async {
      await controller.connectWithSource(ReplaySource(replies), entry);
      for (var i = 0; i < 200 && controller.latest['ODOMETER'] == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await controller.disconnect();
    });
    expect(controller.lastFailures, isEmpty,
        reason: controller.lastFailures.join('\n'));
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: DashboardScreen()),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    // The pack card and health card found their signals under the app's ids.
    expect(controller.latest['HVBAT_SOC'], isNotNull);
    expect(controller.latest['HVBAT_SOH'], isNotNull);
    expect(controller.latest['HVBAT_CURRENT'], isNotNull);
    // Cycle count from the truck's own capacity figure, and it says so.
    expect(find.text('Equivalent full cycles'), findsOneWidget);
    expect(find.textContaining('the capacity the car reports'),
        findsOneWidget);
    // Ages read as years; a few named sections are present.
    expect(find.text('12 V battery charge'), findsOneWidget);
    expect(find.text('CHARGING'), findsOneWidget);
    expect(find.text('MOTOR'), findsOneWidget);
    // No pack data in the set, so no capacity test for this vehicle.
    expect(controller.capacityTestAvailable, isFalse);
    controller.startCapacityTest();
    expect(controller.capacityTest, isNull);
  });

  testWidgets('history from a source this vehicle cannot report is not charted',
      (tester) async {
    final set = SignalSet.parse(
        File('signalsets/BMW-330e-2018/v02.json').readAsStringSync());
    final bmw = SignalSetRepository.catalogue
        .firstWhere((v) => v.id == 'BMW-330e-2018');
    final controller = AppController(repository: _FixedRepo(set));
    await tester.runAsync(() async {
      await controller.connectWithSource(SimulatedBmwSource(), bmw);
      for (var i = 0; i < 100 && controller.latest['HVBAT_SOH'] == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await controller.disconnect();
    });
    // A stray point already saved by the old bug: a Lyriq BMS index (93)
    // filed under the BMW.
    for (final (source, v) in [
      (SohSource.reported, 84.0),
      (SohSource.bmsIndex, 93.0)
    ]) {
      controller.sohHistory.record(SohEntry(
          at: DateTime(2026, 10, 1),
          vehicle: 'BMW-330e-2018',
          source: source,
          sohPct: v));
    }
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: DashboardScreen()),
      ),
    );
    final chart =
        tester.widget<SohHistoryChart>(find.byType(SohHistoryChart));
    expect(chart.series.keys, [SohSource.reported]);
    expect(find.text('BMS index'), findsNothing);
    controller.dispose();
  });

  testWidgets('settings: the temperature toggle flips the controller',
      (tester) async {
    final controller = AppController();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    // Reachable from the home screen.
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(controller.units.temperature, TemperatureUnit.celsius);

    await tester.tap(find.text('°F'));
    await tester.pumpAndSettle();
    expect(controller.units.temperature, TemperatureUnit.fahrenheit);
    await tester.tap(find.text('°C'));
    await tester.pumpAndSettle();
    expect(controller.units.temperature, TemperatureUnit.celsius);

    // Distance is its own switch and leaves temperature alone.
    expect(controller.units.distance, DistanceUnit.kilometers);
    await tester.tap(find.text('mi'));
    await tester.pumpAndSettle();
    expect(controller.units.distance, DistanceUnit.miles);
    expect(controller.units.temperature, TemperatureUnit.celsius);
    await tester.tap(find.text('km'));
    await tester.pumpAndSettle();
    expect(controller.units.distance, DistanceUnit.kilometers);
    controller.dispose();
  });

  testWidgets('dashboard distances and speeds follow the distance unit',
      (tester) async {
    Reading reading(
            String id, String name, String group, String unit, double v) =>
        Reading(
            Signal(
                id: id,
                name: name,
                group: group,
                fmt: SignalFormat(len: 32, unit: unit)),
            v,
            DateTime.now());
    final controller = AppController();
    controller.latest.addAll({
      'ODOMETER': reading('ODOMETER', 'Odometer', 'vehicle', 'km', 77698),
      'VEHICLE_SPEED':
          reading('VEHICLE_SPEED', 'Vehicle speed', 'dynamics', 'km/h', 100),
      'AMBIENT_TEMP':
          reading('AMBIENT_TEMP', 'Ambient', 'temperature', 'celsius', 10),
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: DashboardScreen()),
      ),
    );
    // One unit at a time: km only, no miles alongside.
    expect(find.text('77698 km'), findsOneWidget);
    expect(find.text('100.0 km/h'), findsOneWidget);
    expect(find.textContaining(' mi'), findsNothing);

    controller.setDistanceUnit(DistanceUnit.miles);
    await tester.pumpAndSettle();
    expect(find.text('48279 mi'), findsOneWidget);
    expect(find.text('62.1 mph'), findsOneWidget);
    expect(find.textContaining('km'), findsNothing);
    // Temperature is untouched by the distance switch.
    expect(find.text('10.0 °C'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('dashboard temperatures follow the display unit, verdict fixed',
      (tester) async {
    Reading temp(String id, String name, double v) => Reading(
        Signal(
            id: id,
            name: name,
            group: 'temperature',
            fmt: const SignalFormat(len: 16, unit: 'celsius')),
        v,
        DateTime.now());
    final controller = AppController();
    controller.latest.addAll({
      // A min/avg/max triple: 20 / 22 / 26 °C, a 6 °C spread ("watch").
      'HVBAT_CELLTEMP_MIN': temp('HVBAT_CELLTEMP_MIN', 'Cell temp (min)', 20),
      'HVBAT_CELLTEMP_AVG': temp('HVBAT_CELLTEMP_AVG', 'Cell temp (avg)', 22),
      'HVBAT_CELLTEMP_MAX': temp('HVBAT_CELLTEMP_MAX', 'Cell temp (max)', 26),
      // A plain reading outside the battery card.
      'AMBIENT_TEMP': temp('AMBIENT_TEMP', 'Ambient temperature', 10),
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: DashboardScreen()),
      ),
    );
    Color chipColor(String text) =>
        tester.widget<Text>(find.text(text)).style!.color!;

    expect(find.text('spread 6.0 °C'), findsOneWidget);
    expect(find.text('10.0 °C'), findsOneWidget);
    expect(find.textContaining('°F'), findsNothing);
    final celsiusVerdict = chipColor('spread 6.0 °C');

    controller.setTemperatureUnit(TemperatureUnit.fahrenheit);
    await tester.pumpAndSettle();
    // 6 °C spread = 10.8 °F; 10 °C = 50 °F; min 20 °C = 68 °F.
    expect(find.text('spread 10.8 °F'), findsOneWidget);
    expect(find.text('50.0 °F'), findsOneWidget);
    expect(find.textContaining('68.0'), findsOneWidget);
    expect(find.textContaining('°C'), findsNothing);
    // Same data, same verdict colour.
    expect(chipColor('spread 10.8 °F'), celsiusVerdict);
    controller.dispose();
  });

  testWidgets('drive screen shows motor gauges for a vehicle that has them',
      (tester) async {
    final set = SignalSet.parse(
        File('signalsets/BMW-330e-2018/v02.json').readAsStringSync());
    final bmw = SignalSetRepository.catalogue
        .firstWhere((v) => v.id == 'BMW-330e-2018');
    final controller = AppController(repository: _FixedRepo(set))
      ..driveExtrasSpacing = const Duration(milliseconds: 50);
    // Tall enough that the whole (lazily built) drive list is on screen.
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Drive mode is started outside the test's fake clock so its poll loop
    // really runs; the screen then joins the session already in progress.
    await tester.runAsync(() async {
      await controller.connectWithSource(SimulatedBmwSource(), bmw);
      controller.startDriveMode();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: DriveScreen()),
      ),
    );
    await tester.pump(); // post-frame startDriveMode(): already running

    expect(find.text('Motor'), findsOneWidget);
    // Labels drop the "(unconfirmed)" qualifier; the units keep their "?".
    for (final label in [
      'Motor temperature 1',
      'Motor temperature 2',
      'Motor speed',
      'Motor torque, actual',
      'Motor torque, target',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('°C?'), findsNWidgets(2));
    expect(find.text('rpm?'), findsOneWidget);
    expect(find.text('Nm?'), findsNWidgets(2));
    expect(find.textContaining('has not been confirmed'), findsOneWidget);
    // An unverified temperature is never converted.
    controller.setTemperatureUnit(TemperatureUnit.fahrenheit);
    await tester.pump();
    expect(find.text('°C?'), findsNWidgets(2));
    expect(find.textContaining('°F'), findsNothing);

    await tester.runAsync(controller.disconnect);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('drive screen has no motor card without motor signals',
      (tester) async {
    final set = SignalSet.parse(
        File('signalsets/Cadillac-Lyriq-2025/v02.json').readAsStringSync());
    final lyriq = SignalSetRepository.catalogue
        .firstWhere((v) => v.id == 'Cadillac-Lyriq-2025');
    final controller = AppController(repository: _FixedRepo(set));
    // Tall enough that the whole (lazily built) drive list is on screen.
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await controller.connectWithSource(SimulatedLyriqSource(), lyriq);
      controller.startDriveMode();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: DriveScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('kW'), findsOneWidget);
    expect(find.text('Motor'), findsNothing);
    expect(find.textContaining('Polling pack current only'), findsOneWidget);

    await tester.runAsync(controller.disconnect);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('drive screen explains itself when nothing is connected',
      (tester) async {
    final controller = AppController();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: DriveScreen()),
      ),
    );
    await tester.pump(); // post-frame startDriveMode() -> unsupported
    expect(find.textContaining('needs a live pack-current signal'),
        findsOneWidget);
    controller.dispose();
  });

  testWidgets('signal check lists what the vehicle answered', (tester) async {
    final set = SignalSet.parse(
        File('signalsets/BMW-330e-2018/v02.json').readAsStringSync());
    final controller = AppController(repository: _FixedRepo(set));
    final bmw = SignalSetRepository.catalogue
        .firstWhere((v) => v.id == 'BMW-330e-2018');
    await tester.runAsync(
        () => controller.connectWithSource(SimulatedBmwSource(), bmw, demo: true));
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: SignalCheckScreen()),
      ),
    );
    final start = find.text('Check ${set.commands.length} requests');
    expect(start, findsOneWidget);
    await tester.tap(start);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pumpAndSettle();

    // The demo car answers everything its signal set asks.
    expect(find.text('${set.commands.length} answered, 0 rejected, 0 silent'),
        findsOneWidget);
    expect(find.text('Control unit 6F1 -> 607 (07)', skipOffstage: false),
        findsOneWidget);
    expect(find.byTooltip('Share report'), findsOneWidget);
    expect(controller.adapterHeld, isFalse);
    await tester.runAsync(controller.disconnect);
    controller.dispose();
  });
}
