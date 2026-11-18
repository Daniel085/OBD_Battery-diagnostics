# CLAUDE.md — OBD Battery Diagnostics

Flutter app that reads high-voltage battery / BMS diagnostics from EVs over a
BLE ELM327 adapter (and DoIP/ENET), driven by per-vehicle JSON signal sets.
Target vehicles: 2018 BMW 330e (F30 PHEV) and 2025 Cadillac Lyriq (GM Ultium),
both ours and read on-vehicle. Also in the app, imported from OBDb and NOT
read by us: Ford F-150 Lightning (2022-2025) and F-150 PowerBoost hybrid
(2021+); see `docs/obdb-imports.md`.

## Non-negotiable invariants

- **Read-only.** The app only issues diagnostic reads (UDS `0x22`/`0x19`,
  J1979 mode 01). Never add code that writes to, codes, or clears an ECU.
- **Vehicle knowledge lives in data, not code.** All per-vehicle DIDs/PIDs,
  offsets, and formulas belong in `signalsets/<vehicle>/vXX.json` (OBDb v3
  schema, see `signalsets/signalset.schema.json`). No vehicle-specific logic
  in `lib/`.
- **Protocol + engine layers are pure Dart** (no Flutter imports) so the full
  decode path runs under `flutter test` with no device, adapter, or car.

## Where the truth lives

The README status section lags. Current state is tracked in `docs/` and git log:

- `docs/lyriq-did-map.md` — consolidated Lyriq DID map; which signals are
  confirmed on-vehicle (✓) vs hypothesis (⚠), and the ECU CB gateway analysis.
- `docs/on-vehicle-validation.md` — validation checklist per vehicle.
- `docs/lyriq-re-log.md` — reverse-engineering session log.
- `docs/reverse-engineering.md`, `docs/protocol.md`, `docs/doip-enet.md` —
  methodology and protocol references.
- `captures/` — raw on-vehicle captures; used as replay fixtures.
- `docs/obdb-imports.md` — vehicles imported from OBDb (the Fords): how the
  import tool and its map files work, what is confirmed by whom, and the
  checks to run on a first session with a truck.
- `docs/write-access-ideas.md` — parking lot of routine/write candidates and
  the guardrails they would need. Ideas only; the read-only rule stands.

## Current on-vehicle status (as of Aug 2026)

- **Lyriq:** pack voltage, battery temps, and pack current (ECU 17, DID `2414`)
  confirmed on-vehicle; usable capacity measured ~100% SoH via the
  coulomb-counting capacity test. Confirmed signals were contributed upstream
  as OBDb/Cadillac-LYRIQ#14 (staged in `contrib/obdb-cadillac-lyriq`).
- **Lyriq hard blocker:** ECU CB (Battery System Manager) answers J1979 but the
  central gateway **filters UDS requests to it**. This is proven on-vehicle and
  is NOT fixable via adapter upgrades, AT headers, flow control, or sessions —
  do not burn time retrying software workarounds; it needs bus access behind
  the gateway. ECU 53 exists but is security-locked.
- **BMW 330e:** J1979 PIDs AND the SME (BMS, ext address 07) both read
  on-vehicle over the OBD port (2026-11-08, Viecar clone): SOC + window bounds,
  current, cell temps, cell V/SoC min/max/avg, SOH 83 % (i3 layout, not
  ground-truthed). See `docs/bmw-330e-sme.md`. The old "SME not on the port"
  claim was a framing bug. Probe: `tools/bmw-sme-probe/sme_probe.py`. Pack
  voltage = `DD66` (i3 `DD68` absent). Open: per-cell DID, SOH ground truth.
  The EME motor signals (`MOTOR_*`, address 3A, i3 layout) were read on the
  car once, parked and charging (2026-11-15): temperatures plausible, speed
  field raw 0 (i3 formula: -5000 rpm, dropped via `nullmin`). Never read with
  the motor turning: units keep `?`. One read in Ready at a standstill tells
  whether the -5000 offset applies (raw `27 10` yes, `00 00` no).
  Also `?`-marked: SME ageing/lifetime signals (group `health`: resistance
  health, isolation, HV-on hours, contactor count) and the DME (address 12)
  12 V recharge history (`LVBAT_*`, DID `409D`). A second read on 2026-11-15
  moved the way the i3 layouts (OVMS) predict, but there is no second-tool
  cross-check. Exception: `HVBAT_AGE_HOURS` is confirmed (+166 h in 166 h of
  wall clock). SME `DD73`/`DD74` are little-endian A·s charge-in/out counters
  (`HVBAT_AH_CHARGED` confirmed against integrated current, `_DISCHARGED`
  still `?`); the signal format has a local `"le": true` option for them.
  Charge of 2026-11-15 (`captures/bmw_chg_2026-11-15.txt`): 16.2 Ah per
  100 % SOC, which supports SOH 83 % (lands on 83–88 % depending on BMW's
  as-new figure). `DDBC` SOC is the usable-window SOC; cell SoC is absolute.
  `HVBAT_MODULE_n_DEFECT` (SME `DFA6`, per-module status): 0 = OK confirmed
  by the owner; a non-zero code (never seen, meaning unknown) is a report
  warning. `HVBAT_HV_ON_HOURS` also confirmed (charge-log ticks).
  **While plugged in and charging, SME, DME and EME all answer UDS** though
  J1979 is silent (`sme_probe.py --no-gate`; logger `sme_chglog.py` on the Pi).

## Architecture

```
lib/ui/         screens: home, dashboard, report (+PDF), capacity, scanner, terminal,
                settings
lib/app/        controller, signal-set repository, capacity-test store, settings store,
                capture store (session recordings, check reports, sweeps kept
                on the phone), keep-awake (no auto-lock while connected)
lib/engine/     signal-set loader, formula evaluator, battery health, capacity test,
                SoH history (daily per-vehicle/per-source log, trend),
                display units (°C/°F and km/mi, separate choices, display only;
                data stays in signal-set units; first-run defaults by region),
                diagnostics clients (J1979 + UDS)
lib/protocol/   isotp.dart, uds.dart, doip.dart (pure Dart)
lib/transport/  DataSource impls: elm_ble_source (BLE ELM327), doip_source,
                simulated_source, bmw_cardata_source (feature-flagged);
                recording_source (wraps the live source, one text line per
                exchange; `Recording.parse` reads a capture back)
lib/tools/      uds_scanner (DID sweeps), correlation (signal identification),
                signal_check (every request of a signal set once: answered /
                rejected / silent, shareable report with the raw replies)
tools/          bmw-sme-probe, pi-logger (Pi-side scripts); obdb-import
                (OBDb signal set -> app signal set + replay fixtures)
```

New data paths get a `ReplaySource`/capture-based test in `test/` — that's the
established pattern (18 test files, all offline).

## Commands

```bash
flutter pub get
flutter test          # full suite, no hardware needed
flutter analyze       # keep clean
flutter run           # on-device; demo mode works with no adapter/car
flutter run -d <simulator-udid>   # iOS Simulator (see gotcha below)
```

## Hardware gotchas (hard-won, don't rediscover)

- **Viecar/clone BLE trap:** some adapters expose a bogus writable char at
  FFF2 — write-characteristic selection logic in
  `lib/transport/elm_ble_source.dart` handles this; don't "simplify" it.
- If connected but silent, the adapter may use Nordic-UART GATT layout:
  `ElmBleConfig.nordicUart()` vs the default FFE0/FFE1.
- Lyriq is 29-bit CAN (`ATSP7`), request `18DA<ecu>F1` / response
  `18DAF1<ecu>`; cheap clones struggle with 29-bit multiframe — prefer
  OBDLink CX/MX+.
- **Pack-current sign:** the app's `HVBAT_CURRENT` is positive = discharge,
  negative = charge/regen (dashboard, drive mode and capacity test all rely
  on it). The Lyriq reports that natively; the BMW SME reports the opposite,
  so its signal set negates it (`mul: -1`). Check the sign on any new vehicle
  against a known charge AND a known load.
- **BMW extended addressing:** request `6F1: 07 03 22 DD BC`, response
  `607: F1 05 62 ...`. The target byte comes BEFORE the PCI, so prepending
  `07` to a line while CAN auto-formatting is on (`04 07 22 ...`) is silently
  wrong. Use `extendedAddressingCommands()`: ATCEA07 + custom FC
  `07 30 00 00` (the clone's own FC omits the address → only the First Frame
  arrives) + ATAT0/ATSTFF (the SME sends `7F 22 78` pending first). ATSTFF
  makes every read take ~1.25 s; drive mode uses `DiagnosticsClient.fastTiming`
  (ATST40 → 80 → FF, steps back on a missed reply, per ECU). Shorter waits are
  NOT yet confirmed on the car.
- **Slow values:** a command with `"freq": <seconds>` in the signal set is
  re-read in a full poll only after that long (each BMW SME read costs
  ~1.25 s). `readAll` then returns fewer signals than the poll before; merge,
  don't replace.
- **Per-vehicle facts live in the signal set's `pack` block:** `ratedAh`
  (cycle count), `ratedKwh` + `nominalVoltage` (capacity test; without both
  the test is not offered for that vehicle). Logic keys on canonical signal
  ids (`HVBAT_SOC`, `HVBAT_CURRENT`, `HVBAT_*_MIN/_MAX/_AVG`, `LVBAT_*`,
  `MOTOR_*`); an imported set must use them for its cards to appear.
- **Imported sets are generated:** edit `tools/obdb-import/*.map.json` and
  rerun the tool, don't hand-edit `signalsets/Ford-*`. OBDb's `fcm1` flag is
  carried but not acted on.
- **Display-only conveniences (data stays as read):** a verified `hours`
  value is shown as days or years (`DisplayUnits.display`); `fmt.map` names
  values (`0` → "OK"); `pack.ratedAh` in a signal set turns lifetime Ah into
  the report's `equivalent_full_cycles`. `fmt.le` reads little-endian fields.
- **One talker at a time:** the adapter takes one command at a time and
  keeps header/filter state. Anything that talks to it outside the poll loop
  (terminal, DID scanner, signal check) goes through
  `AppController.withAdapter` / `holdAdapter`, which pauses polling and makes
  the client set its addressing again afterwards.
- **Phone-only captures:** every real-adapter session is recorded to
  `Documents/captures/` on the phone as it happens (demo sessions are not);
  signal-check reports and sweeps are saved there too. Pull them with
  `xcrun devicectl device copy from ... --domain-type appDataContainer
  --domain-identifier com.obddiag.obdBatteryDiagnostics --source
  Documents/captures` or share from the Captures screen. `activeSource` is
  the recording wrapper; use `bleSource` for the BLE adapter itself.
- **Drive-mode extras:** signals whose id starts with `MOTOR_` are read every
  ~4 s between pack-current samples and shown as dials. On BMW that means
  re-addressing the adapter to another ECU and back, which pauses the power
  feed; a command that fails 3 times in a row is dropped for that session.

- **iOS build (Flutter 3.44 + current Xcode):** deployment target must be
  ≥ 15.0 (raised from 13.0). `flutter build ios --simulator` fails at
  `debug_unpack_ios` ("does not contain architectures arm64 x86_64") because
  this Xcode's `lipo -verify_arch` rejects Flutter's arguments; use
  `flutter run -d <simulator-udid>` (builds only arm64) instead.

## Contribution / licensing

Signal sets follow the OBDb v3 schema and are shared back upstream
(CC BY-SA 4.0). When a signal is confirmed on-vehicle: promote it out of
`_unconfirmed_*`, bump the signalset version (`v01` → `v02`) with provenance
notes, and stage upstream contributions under `contrib/` following upstream
conventions (LYRIQ_ prefix, DAxx headers, schema-validated).
