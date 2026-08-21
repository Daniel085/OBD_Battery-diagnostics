import 'dart:io';

import 'package:obd_battery_diagnostics/engine/diagnostics_client.dart';
import 'package:obd_battery_diagnostics/engine/signal_set.dart';
import 'package:obd_battery_diagnostics/transport/simulated_source.dart';
import 'package:test/test.dart';

void main() {
  test('simulated BMW source drives a full decode via DiagnosticsClient',
      () async {
    final set = SignalSet.parse(
        File('signalsets/BMW-330e-2018/v01.json').readAsStringSync());
    final source = SimulatedBmwSource();
    await source.connect();
    final client = DiagnosticsClient(source, set);
    await client.initialize();

    final failures = <CommandFailure>[];
    final all = await client.readAll(onFailure: failures.add);

    // Every BMW signal should decode with a plausible value.
    expect(failures, isEmpty, reason: failures.join('\n'));
    expect(all['HVBAT_SOC']!.value, inInclusiveRange(0, 100));
    expect(all['HVBAT_SOH']!.value, inInclusiveRange(50, 100));
    expect(all['HVBAT_VOLTAGE']!.value, inInclusiveRange(200, 450));
    expect(all['HVBAT_CELL_V_MIN']!.value, inInclusiveRange(3.0, 4.3));
    expect(all['HVBAT_CELL_V_MAX']!.value,
        greaterThanOrEqualTo(all['HVBAT_CELL_V_MIN']!.value));
    expect(all['HVBAT_CELLTEMP_MAX']!.value,
        greaterThanOrEqualTo(all['HVBAT_CELLTEMP_MIN']!.value));
  });

  test('simulated Lyriq source answers the ENTIRE Lyriq signal set', () async {
    final set = SignalSet.parse(
        File('signalsets/Cadillac-Lyriq-2025/v01.json').readAsStringSync());
    final source = SimulatedLyriqSource();
    await source.connect();
    final client = DiagnosticsClient(source, set);
    await client.initialize();

    final failures = <CommandFailure>[];
    final all = await client.readAll(onFailure: failures.add);

    // No signal may fail — the demo must exercise every confirmed signal.
    expect(failures, isEmpty, reason: failures.join('\n'));
    expect(all.length, set.signalsById.length,
        reason: 'every signal in the set decodes');

    // The charge simulation: steady ~-22.75 A so the capacity test demos.
    expect(all['HVBAT_CURRENT']!.value, inInclusiveRange(-23.1, -22.4));
    expect(all['HVBAT_NOMINAL_VOLTAGE']!.value, closeTo(352.09, 0.01));
    expect(all['HVBAT_MODULE_V_1']!.value, inInclusiveRange(50.5, 51.5));
    expect(all['HVBAT_TEMP_1']!.value, inInclusiveRange(30, 35));
    expect(all['EVSE_PILOT_CURRENT']!.value, closeTo(38.8, 0.001));
    expect(all['ODOMETER']!.value, closeTo(31737.28, 0.1));
    expect(all['LV_RAIL_VOLTAGE']!.value, inInclusiveRange(13.1, 13.4));
    expect(all['VEHICLE_SPEED']!.value, 0); // parked while charging
    expect(all['WHEEL_SPEED_FL']!.value, 0);
  });
}
