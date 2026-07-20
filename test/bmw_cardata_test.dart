import 'package:obd_battery_diagnostics/transport/bmw_cardata_source.dart';
import 'package:test/test.dart';

class _FakeCarDataApi implements CarDataApi {
  final Map<String, double> snapshot;
  _FakeCarDataApi(this.snapshot);

  @override
  Future<Map<String, double>> fetchLatest() async => snapshot;

  @override
  Stream<MapEntry<String, double>> stream() =>
      Stream.fromIterable(snapshot.entries);
}

void main() {
  test('maps CarData descriptors onto internal signal ids', () async {
    final api = _FakeCarDataApi({
      'vehicle.powertrain.electric.battery.stateOfCharge': 61.5,
      'vehicle.powertrain.electric.battery.stateOfHealth': 92.0,
      'some.unmapped.descriptor': 1.0, // ignored
    });
    final source = BmwCarDataSource(api);
    final readings = await source.readLatest(now: DateTime.utc(2026, 1, 1));

    expect(readings.keys, containsAll(['HVBAT_SOC', 'HVBAT_SOH']));
    expect(readings['HVBAT_SOC']!.value, 61.5);
    expect(readings['HVBAT_SOC']!.unit, 'percent');
    expect(readings.containsKey('some.unmapped.descriptor'), isFalse);
  });

  test('streams mapped readings', () async {
    final api = _FakeCarDataApi({
      'vehicle.powertrain.electric.battery.stateOfCharge': 55.0,
    });
    final source = BmwCarDataSource(api);
    final ids = await source.readings().map((r) => r.signal.id).toList();
    expect(ids, contains('HVBAT_SOC'));
  });
}
