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
          // Two separate choices: the UK pairs Celsius with miles.
          _UnitTile<TemperatureUnit>(
            title: 'Temperature',
            subtitle: 'Battery and coolant temperatures',
            options: const {
              TemperatureUnit.celsius: '°C',
              TemperatureUnit.fahrenheit: '°F',
            },
            selected: c.units.temperature,
            onChanged: c.setTemperatureUnit,
          ),
          _UnitTile<DistanceUnit>(
            title: 'Distance',
            subtitle: 'Odometer and speeds',
            options: const {
              DistanceUnit.kilometers: 'km',
              DistanceUnit.miles: 'mi',
            },
            selected: c.units.distance,
            onChanged: c.setDistanceUnit,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'These change what you see on screen and in printed reports. '
              'CSV and JSON exports and saved recordings stay in Celsius and '
              'kilometres.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// One unit choice: a title and a two-way switch.
class _UnitTile<T> extends StatelessWidget {
  final String title, subtitle;
  final Map<T, String> options;
  final T selected;
  final ValueChanged<T> onChanged;

  const _UnitTile({
    required this.title,
    required this.subtitle,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: SegmentedButton<T>(
        showSelectedIcon: false,
        segments: [
          for (final MapEntry(key: value, value: label) in options.entries)
            ButtonSegment(value: value, label: Text(label)),
        ],
        selected: {selected},
        onSelectionChanged: (s) => onChanged(s.first),
      ),
    );
  }
}
