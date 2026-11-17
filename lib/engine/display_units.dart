/// Display-unit preferences: how values are SHOWN, never how they are read
/// or stored.
///
/// Signal sets, logs, CSV/JSON exports and health thresholds stay in the
/// signal set's own units (temperatures in Celsius, distances in km). Only
/// on-screen and printed text goes through [DisplayUnits], so a preference
/// can never change a recorded number or a verdict.
///
/// Temperature and distance are separate choices on purpose: the UK pairs
/// Celsius with miles, so one switch for both would be wrong there.
///
/// Pure Dart, no Flutter imports.
library;

enum TemperatureUnit { celsius, fahrenheit }

enum DistanceUnit { kilometers, miles }

const double kmPerMile = 1.609344;

class DisplayUnits {
  final TemperatureUnit temperature;
  final DistanceUnit distance;

  const DisplayUnits({
    this.temperature = TemperatureUnit.celsius,
    this.distance = DistanceUnit.kilometers,
  });

  /// Regions (ISO 3166-1 alpha-2) that show temperatures in Fahrenheit: the
  /// US and its territories, plus the few other countries that use it.
  static const _fahrenheitRegions = {
    'US', 'PR', 'GU', 'VI', 'AS', 'MP', // United States + territories
    'BS', 'BZ', 'KY', 'LR', 'PW', 'FM', 'MH',
  };

  /// Regions whose roads are signed in miles: the Fahrenheit regions, plus
  /// the UK and Crown Dependencies (Celsius, but miles).
  static const _mileRegions = {
    ..._fahrenheitRegions,
    'GB',
    'IM',
    'JE',
    'GG',
  };

  /// First-run defaults for a device region. Unknown or missing regions get
  /// Celsius and kilometres. A saved choice always wins over this.
  factory DisplayUnits.forRegion(String? countryCode) {
    final region = countryCode?.toUpperCase();
    return DisplayUnits(
      temperature: _fahrenheitRegions.contains(region)
          ? TemperatureUnit.fahrenheit
          : TemperatureUnit.celsius,
      distance: _mileRegions.contains(region)
          ? DistanceUnit.miles
          : DistanceUnit.kilometers,
    );
  }

  DisplayUnits copyWith(
          {TemperatureUnit? temperature, DistanceUnit? distance}) =>
      DisplayUnits(
        temperature: temperature ?? this.temperature,
        distance: distance ?? this.distance,
      );

  /// Signal sets mark an unverified unit with a trailing `?` (`celsius?`):
  /// a value we can scale but have not identified. Such a value is shown as
  /// read and never converted, because converting it would claim we know
  /// what it measures.
  static (String, String) _split(String unit) => unit.endsWith('?')
      ? (unit.substring(0, unit.length - 1), '?')
      : (unit, '');

  /// How a signal-set unit is displayed under these preferences: the display
  /// unit and `display = value * scale + offset`. Null when shown as-is,
  /// which includes every unverified unit.
  ({String unit, double scale, double offset})? _rule(String unit) =>
      switch (unit) {
        'celsius' when temperature == TemperatureUnit.fahrenheit => (
            unit: 'fahrenheit',
            scale: 9 / 5,
            offset: 32,
          ),
        'km' when distance == DistanceUnit.miles => (
            unit: 'mi',
            scale: 1 / kmPerMile,
            offset: 0,
          ),
        'km/h' when distance == DistanceUnit.miles => (
            unit: 'mph',
            scale: 1 / kmPerMile,
            offset: 0,
          ),
        _ => null,
      };

  /// The unit a value in signal-set [unit] is displayed in.
  String unitFor(String unit) => _rule(unit)?.unit ?? unit;

  /// An absolute value (a reading) converted for display.
  double convert(String unit, double value) {
    final rule = _rule(unit);
    return rule == null ? value : value * rule.scale + rule.offset;
  }

  /// A difference (spread, rise) converted for display: scaled, no offset.
  double convertDelta(String unit, double delta) {
    final rule = _rule(unit);
    return rule == null ? delta : delta * rule.scale;
  }

  /// 365.25 days.
  static const hoursPerYear = 8766.0;

  /// A duration in hours, in the unit it reads best in: hours up to a day,
  /// days up to a year, years beyond that.
  static ({double value, String unit}) readableHours(double hours) {
    final h = hours.abs();
    if (h < 24) return (value: hours, unit: 'h');
    if (h < hoursPerYear) return (value: hours / 24, unit: 'days');
    return (value: hours / hoursPerYear, unit: 'years');
  }

  /// A value and the unit symbol to show beside it. Verified `hours` become
  /// days or years when that reads better; everything else is [convert] and
  /// [symbolFor].
  ({double value, String unit}) display(String unit, double value) =>
      unit == 'hours'
          ? readableHours(value)
          : (value: convert(unit, value), unit: symbolFor(unit));

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
      'kiloohms' => 'kΩ',
      'hours' => 'h',
      'amp_hours' => 'Ah',
      _ => base,
    };
    return '$s$mark';
  }

  /// Symbol of the unit a value in signal-set [unit] is displayed in.
  String symbolFor(String unit) => symbol(unitFor(unit));

  Map<String, dynamic> toJson() => {
        'temperature': temperature.name,
        'distance': distance.name,
      };

  /// Each field that is missing or unrecognised takes its value from
  /// [defaults], so an older or newer settings file never fails to load and
  /// a setting added later starts at the region default.
  factory DisplayUnits.fromJson(Map<String, dynamic> j,
          {DisplayUnits defaults = const DisplayUnits()}) =>
      DisplayUnits(
        temperature: TemperatureUnit.values.firstWhere(
          (t) => t.name == j['temperature'],
          orElse: () => defaults.temperature,
        ),
        distance: DistanceUnit.values.firstWhere(
          (d) => d.name == j['distance'],
          orElse: () => defaults.distance,
        ),
      );

  @override
  bool operator ==(Object other) =>
      other is DisplayUnits &&
      other.temperature == temperature &&
      other.distance == distance;

  @override
  int get hashCode => Object.hash(temperature, distance);

  @override
  String toString() => 'DisplayUnits(${temperature.name}, ${distance.name})';
}
