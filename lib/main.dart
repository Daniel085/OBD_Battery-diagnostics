import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app/app_controller.dart';
import 'app/capacity_test_store.dart';
import 'app/onboarding_store.dart';
import 'ui/home_screen.dart';

void main() {
  runApp(const ObdBatteryApp());
}

class ObdBatteryApp extends StatelessWidget {
  const ObdBatteryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppController(
        capacityStore: CapacityTestStore.documents(),
        onboardingStore: OnboardingStore.documents(),
      )
        ..restoreCapacityTest()
        ..restoreOnboarding(),
      child: MaterialApp(
        title: 'OBD Battery Diagnostics',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF00695C),
          ),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF00695C),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
