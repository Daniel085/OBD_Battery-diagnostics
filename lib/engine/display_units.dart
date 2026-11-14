/// Display-unit preferences: how values are SHOWN, never how they are read
/// or stored.
///
/// Signal sets, logs, CSV/JSON exports and health thresholds stay in the
/// signal set's own units (temperatures in Celsius). Only on-screen and
/// printed text goes through [DisplayUnits], so a preference can never change
/// a recorded number or a verdict.
///
/// Pure Dart, no Flutter imports.
library;

enum TemperatureUnit { celsius, fahrenheit }

class DisplayUnits {
  final TemperatureUnit temperature;

  const DisplayUnits({this.temperature = TemperatureUnit.celsius});

  DisplayUnits copyWith({TemperatureUnit? temperature}) =>
      DisplayUnits(temperature: temperature ?? this.temperature);

  /// Signal sets mark an unverified unit with a trailing `?` (`celsius?`).
  /// It is still that unit for conversion, and the mark is kept.
  static (String, String) _split(String unit) => unit.endsWith('?')
      ? (unit.substring(0, unit.length - 1), '?')
      : (unit, '');

  bool _toFahrenheit(String unit) =>
      temperature == TemperatureUnit.fahrenheit && _split(unit).$1 == 'celsius';

  /// The unit a value in signal-set [unit] is displayed in.
  String unitFor(String unit) =>
      _toFahrenheit(unit) ? 'fahrenheit${_split(unit).$2}' : unit;

  /// An absolute value (a temperature reading) converted for display.
  double convert(String unit, double value) =>
      _toFahrenheit(unit) ? value * 9 / 5 + 32 : value;

  /// A difference (spread, rise) converted for display: scaled, no offset.
  double convertDelta(String unit, double delta) =>
      _toFahrenheit(unit) ? delta * 9 / 5 : delta;

  /// Short symbol for a unit name (`celsius` -> `°C`); unknown names pass
  /// through unchanged.
  static String symbol(String unit) {
    final (base, mark) = _split(unit);
    final s = switch (base) {
      'celsius' => '°C',
      'fahrenheit' => '°F',
      'percent' => '%',
      'volts' => 'V',
      'amps' => 'A',
      _ => base,
    };
    return '$s$mark';
  }

  /// Symbol of the unit a value in signal-set [unit] is displayed in.
  String symbolFor(String unit) => symbol(unitFor(unit));

  Map<String, dynamic> toJson() => {'temperature': temperature.name};

  /// Unknown or missing values fall back to the defaults, so an older or
  /// newer settings file never fails to load.
  factory DisplayUnits.fromJson(Map<String, dynamic> j) => DisplayUnits(
        temperature: TemperatureUnit.values.firstWhere(
          (t) => t.name == j['temperature'],
          orElse: () => TemperatureUnit.celsius,
        ),
      );

  @override
  bool operator ==(Object other) =>
      other is DisplayUnits && other.temperature == temperature;

  @override
  int get hashCode => temperature.hashCode;
}
