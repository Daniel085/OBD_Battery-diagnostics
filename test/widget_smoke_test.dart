import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:obd_battery_diagnostics/app/app_controller.dart';
import 'package:obd_battery_diagnostics/app/signal_set_repository.dart';
import 'package:obd_battery_diagnostics/engine/diagnostics_client.dart';
import 'package:obd_battery_diagnostics/engine/signal_set.dart';
import 'package:obd_battery_diagnostics/transport/simulated_source.dart';
import 'package:obd_battery_diagnostics/ui/dashboard_screen.dart';
import 'package:obd_battery_diagnostics/ui/drive_screen.dart';
import 'package:obd_battery_diagnostics/ui/home_screen.dart';

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
        File('signalsets/Cadillac-Lyriq-2025/v01.json').readAsStringSync());
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
    expect(find.text('CELLS'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('DYNAMICS'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('DYNAMICS'), findsOneWidget);
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
    expect(
        find.textContaining('needs a live pack-current signal'), findsOneWidget);
    controller.dispose();
  });
}
