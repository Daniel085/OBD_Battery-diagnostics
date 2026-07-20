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
}
