import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:obd_battery_diagnostics/app/app_controller.dart';
import 'package:obd_battery_diagnostics/app/signal_set_repository.dart';
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
}
