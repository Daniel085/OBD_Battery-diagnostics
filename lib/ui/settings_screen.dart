import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/app_controller.dart';
import '../engine/display_units.dart';

/// App preferences. Display-only: nothing here changes what is read from the
/// car or what is written to logs and exports.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<AppController>();
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          ListTile(
            title: const Text('Temperature'),
            subtitle: const Text(
                'How temperatures are shown. CSV and JSON exports stay in '
                'Celsius.'),
            trailing: SegmentedButton<TemperatureUnit>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                    value: TemperatureUnit.celsius, label: Text('°C')),
                ButtonSegment(
                    value: TemperatureUnit.fahrenheit, label: Text('°F')),
              ],
              selected: {c.units.temperature},
              onSelectionChanged: (s) => c.setTemperatureUnit(s.first),
            ),
          ),
        ],
      ),
    );
  }
}
