import 'package:obd_battery_diagnostics/engine/display_units.dart';
import 'package:test/test.dart';

void main() {
  const c = DisplayUnits();
  const f = DisplayUnits(temperature: TemperatureUnit.fahrenheit);

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

  test('an unverified unit converts and keeps its mark', () {
    expect(f.convert('celsius?', 10), 50);
    expect(f.unitFor('celsius?'), 'fahrenheit?');
    expect(f.symbolFor('celsius?'), '°F?');
    expect(c.symbolFor('celsius?'), '°C?');
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
    expect(DisplayUnits.fromJson({}), c);
    expect(DisplayUnits.fromJson({'temperature': 'kelvin'}), c);
    expect(DisplayUnits.fromJson({'temperature': 7}), c);
  });
}
