# CLAUDE.md — OBD Battery Diagnostics

Flutter app that reads high-voltage battery / BMS diagnostics from EVs over a
BLE ELM327 adapter (and DoIP/ENET), driven by per-vehicle JSON signal sets.
Target vehicles: 2018 BMW 330e (F30 PHEV) and 2025 Cadillac Lyriq (GM Ultium).

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

## Architecture

```
lib/ui/         screens: home, dashboard, report (+PDF), capacity, scanner, terminal,
                settings
lib/app/        controller, signal-set repository, capacity-test store, settings store
lib/engine/     signal-set loader, formula evaluator, battery health, capacity test,
                SoH history (daily per-vehicle/per-source log, trend),
                display units (°C/°F and km/mi, separate choices, display only;
                data stays in signal-set units; first-run defaults by region),
                diagnostics clients (J1979 + UDS)
lib/protocol/   isotp.dart, uds.dart, doip.dart (pure Dart)
lib/transport/  DataSource impls: elm_ble_source (BLE ELM327), doip_source,
                simulated_source, bmw_cardata_source (feature-flagged)
lib/tools/      uds_scanner (DID sweeps), correlation (signal identification)
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
- **BMW extended addressing:** request `6F1: 07 03 22 DD BC`, response
  `607: F1 05 62 ...`. The target byte comes BEFORE the PCI, so prepending
  `07` to a line while CAN auto-formatting is on (`04 07 22 ...`) is silently
  wrong. Use `extendedAddressingCommands()`: ATCEA07 + custom FC
  `07 30 00 00` (the clone's own FC omits the address → only the First Frame
  arrives) + ATAT0/ATSTFF (the SME sends `7F 22 78` pending first).

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
