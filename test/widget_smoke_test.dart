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
import 'package:obd_battery_diagnostics/transport/simulated_source.dart';
import 'package:obd_battery_diagnostics/ui/dashboard_screen.dart';
import 'package:obd_battery_diagnostics/ui/drive_screen.dart';
import 'package:obd_battery_diagnostics/ui/home_screen.dart';
import 'package:obd_battery_diagnostics/ui/settings_screen.dart';

// Compiling this file forces the whole UI tree (home/dashboard/report screens,
// the PDF renderer, and the BLE-source imports) through the compiler, catching
// integration errors that pure-Dart tests miss. We construct the controller
// without touching real BLE (no scan is started), so it is device-independent.
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
}
