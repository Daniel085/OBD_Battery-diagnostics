/// Tests for ElmBleSource.pickRoles — the GATT role-selection policy.
///
/// The Viecar case is the one that bit us on-vehicle: its FFF1 characteristic
/// advertises notify AND write, but the firmware only accepts commands on
/// FFF2 (gatttool recipe: write handle 0x0016 = FFF2, notifications on FFF1).
/// "First writable wins" selected FFF1 for write → every command went into a
/// black hole → adapter silent while connected.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:obd_battery_diagnostics/transport/elm_ble_source.dart';

const _svc = '0000fff0-0000-1000-8000-00805f9b34fb';
const _fff1 = '0000fff1-0000-1000-8000-00805f9b34fb';
const _fff2 = '0000fff2-0000-1000-8000-00805f9b34fb';
const _ffe0 = '0000ffe0-0000-1000-8000-00805f9b34fb';
const _ffe1 = '0000ffe1-0000-1000-8000-00805f9b34fb';

ResolvedGattRoles? pick(List<GattCharInfo> chars) => ElmBleSource.pickRoles(
      chars,
      serviceUuid: _svc,
      writeCharUuid: _fff2,
      notifyCharUuid: _fff1,
    );

void main() {
  test('Viecar layout: write goes to FFF2 even when FFF1 is also writable',
      () {
    // FFF1 enumerates first and advertises notify+write — the trap.
    final roles = pick(const [
      GattCharInfo(
          serviceId: _svc, charId: _fff1, notify: true, writeNoResp: true),
      GattCharInfo(serviceId: _svc, charId: _fff2, writeNoResp: true),
    ]);
    expect(roles, isNotNull);
    expect(roles!.notify.charId, _fff1);
    expect(roles.write.charId, _fff2);
  });

  test('clean Viecar layout (FFF1 notify-only, FFF2 write-only)', () {
    final roles = pick(const [
      GattCharInfo(serviceId: _svc, charId: _fff1, notify: true),
      GattCharInfo(serviceId: _svc, charId: _fff2, writeNoResp: true),
    ]);
    expect(roles!.write.charId, _fff2);
    expect(roles.notify.charId, _fff1);
  });

  test('single shared characteristic (FFE1-style) is used for both roles', () {
    final roles = pick(const [
      GattCharInfo(
          serviceId: _ffe0, charId: _ffe1, notify: true, writeNoResp: true),
    ]);
    expect(roles!.write.charId, _ffe1);
    expect(roles.notify.charId, _ffe1);
  });

  test('generic services (Device Info, Battery) never win', () {
    const devInfo = '0000180a-0000-1000-8000-00805f9b34fb';
    const battSvc = '0000180f-0000-1000-8000-00805f9b34fb';
    final roles = pick(const [
      GattCharInfo(
          serviceId: devInfo,
          charId: '00002a29-0000-1000-8000-00805f9b34fb',
          notify: true,
          writeResp: true),
      GattCharInfo(
          serviceId: battSvc,
          charId: '00002a19-0000-1000-8000-00805f9b34fb',
          notify: true),
      GattCharInfo(serviceId: _svc, charId: _fff1, notify: true),
      GattCharInfo(serviceId: _svc, charId: _fff2, writeNoResp: true),
    ]);
    expect(roles!.write.serviceId, _svc);
    expect(roles.notify.serviceId, _svc);
  });

  test('explicitly configured write char beats the distinct-char heuristic',
      () {
    // User overrides config to write on FFF1 (shared): exact match must win
    // over a distinct-but-unconfigured FFF3.
    const fff3 = '0000fff3-0000-1000-8000-00805f9b34fb';
    final roles = ElmBleSource.pickRoles(
      const [
        GattCharInfo(
            serviceId: _svc, charId: _fff1, notify: true, writeNoResp: true),
        GattCharInfo(serviceId: _svc, charId: fff3, writeNoResp: true),
      ],
      serviceUuid: _svc,
      writeCharUuid: _fff1,
      notifyCharUuid: _fff1,
    );
    expect(roles!.write.charId, _fff1);
  });

  test('no usable candidates returns null (falls back to configured UUIDs)',
      () {
    final roles = pick(const [
      GattCharInfo(
          serviceId: '0000180a-0000-1000-8000-00805f9b34fb',
          charId: '00002a29-0000-1000-8000-00805f9b34fb',
          writeResp: true),
    ]);
    expect(roles, isNull);
  });

  test('vendor service preferred is still found when config service absent',
      () {
    // Adapter uses FFE0 while config says FFF0 — vendor family still matches.
    final roles = pick(const [
      GattCharInfo(
          serviceId: _ffe0, charId: _ffe1, notify: true, writeNoResp: true),
    ]);
    expect(roles, isNotNull);
    expect(roles!.notify.charId, _ffe1);
  });
}
