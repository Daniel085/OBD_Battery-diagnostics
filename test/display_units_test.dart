import 'package:obd_battery_diagnostics/engine/display_units.dart';
import 'package:test/test.dart';

void main() {
  const c = DisplayUnits();
  const f = DisplayUnits(temperature: TemperatureUnit.fahrenheit);
  const us = DisplayUnits(
      temperature: TemperatureUnit.fahrenheit, distance: DistanceUnit.miles);

  test('Celsius is the default and changes nothing', () {
    expect(c.temperature, TemperatureUnit.celsius);
    expect(c.convert('celsius', 25), 25);
    expect(c.convertDelta('celsius', 5), 5);
    expect(c.unitFor('celsius'), 'celsius');
    expect(c.symbolFor('celsius'), '°C');
  });

  test('Fahrenheit converts readings with the offset', () {
    expect(f.convert('celsius', 0), 32);
    expect(f.convert('celsius', 100), 212);
    expect(f.convert('celsius', -40), -40);
    expect(f.convert('celsius', 25.31), closeTo(77.558, 1e-9));
    expect(f.unitFor('celsius'), 'fahrenheit');
    expect(f.symbolFor('celsius'), '°F');
  });

  test('Fahrenheit converts differences without the offset', () {
    // A 5 °C spread is a 9 °F spread, not 41 °F.
    expect(f.convertDelta('celsius', 5), 9);
    expect(f.convertDelta('celsius', 0), 0);
    expect(f.convertDelta('celsius', -3), closeTo(-5.4, 1e-9));
  });

  test('other units are never touched', () {
    for (final unit in ['volts', 'percent', 'amps', 'km', 'km/h', 'g', '']) {
      expect(f.convert(unit, 12.5), 12.5, reason: unit);
      expect(f.convertDelta(unit, 12.5), 12.5, reason: unit);
      expect(f.unitFor(unit), unit, reason: unit);
    }
  });

  test('an unverified unit is shown as read, never converted', () {
    // `celsius?` = scaled like a temperature but not identified as one.
    expect(us.convert('celsius?', 10), 10);
    expect(us.convertDelta('celsius?', 10), 10);
    expect(us.unitFor('celsius?'), 'celsius?');
    expect(us.symbolFor('celsius?'), '°C?');
    expect(c.symbolFor('celsius?'), '°C?');
    expect(us.convert('km?', 100), 100);
    expect(us.symbolFor('km/h?'), 'km/h?');
  });

  test('symbols', () {
    expect(DisplayUnits.symbol('volts'), 'V');
    expect(DisplayUnits.symbol('percent'), '%');
    expect(DisplayUnits.symbol('amps'), 'A');
    expect(DisplayUnits.symbol('km/h'), 'km/h');
  });

  test('JSON round-trip, and unknown values fall back to defaults', () {
    expect(DisplayUnits.fromJson(f.toJson()), f);
    expect(DisplayUnits.fromJson(c.toJson()), c);
    expect(DisplayUnits.fromJson(us.toJson()), us);
    expect(DisplayUnits.fromJson({}), c);
    expect(DisplayUnits.fromJson({'temperature': 'kelvin'}), c);
    expect(
        DisplayUnits.fromJson({'temperature': 7, 'distance': 'furlongs'}), c);
  });

  test('a field missing from saved JSON takes the given default', () {
    // A file written before the distance setting existed: the saved
    // temperature is kept, distance starts at the region default.
    expect(DisplayUnits.fromJson({'temperature': 'celsius'}, defaults: us),
        const DisplayUnits(distance: DistanceUnit.miles));
    expect(DisplayUnits.fromJson({}, defaults: us), us);
    // A saved value always beats the default.
    expect(DisplayUnits.fromJson(c.toJson(), defaults: us), c);
  });

  group('distance', () {
    const mi = DisplayUnits(distance: DistanceUnit.miles);

    test('kilometres are the default and change nothing', () {
      expect(c.distance, DistanceUnit.kilometers);
      expect(c.convert('km', 100), 100);
      expect(c.unitFor('km/h'), 'km/h');
    });

    test('miles convert distances and speeds', () {
      expect(mi.convert('km', 1.609344), closeTo(1, 1e-12));
      expect(mi.convert('km', 77698), closeTo(48279.3, 0.05));
      expect(mi.convert('km/h', 100), closeTo(62.137, 0.001));
      expect(mi.convert('km', 0), 0);
      expect(mi.convertDelta('km', 16.09344), closeTo(10, 1e-9));
      expect(mi.unitFor('km'), 'mi');
      expect(mi.unitFor('km/h'), 'mph');
      expect(mi.symbolFor('km'), 'mi');
      expect(mi.symbolFor('km/h'), 'mph');
    });

    test('the two choices are independent (UK: Celsius with miles)', () {
      expect(mi.convert('celsius', 20), 20);
      expect(mi.symbolFor('celsius'), '°C');
      expect(f.convert('km', 100), 100);
      expect(f.symbolFor('km/h'), 'km/h');
    });
  });

  group('region defaults', () {
    DisplayUnits region(String? code) => DisplayUnits.forRegion(code);

    test('US: Fahrenheit and miles', () {
      expect(region('US'), us);
      expect(region('us'), us); // case-insensitive
    });

    test('UK: Celsius and miles', () {
      expect(region('GB'), const DisplayUnits(distance: DistanceUnit.miles));
    });

    test('metric regions, unknown and missing: Celsius and km', () {
      for (final code in ['CA', 'DE', 'FR', 'AU', 'JP', 'MX', 'ZZ', '', null]) {
        expect(region(code), c, reason: '$code');
      }
    });
  });
}
