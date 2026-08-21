# OBD Battery Diagnostics

A cross-platform (Flutter) app that connects to a vehicle's OBD-II port via a BLE ELM327 adapter and retrieves **detailed BMS / high-voltage battery diagnostics** — state of charge, state of health, pack voltage/current, per-cell voltages, module temperatures, cell balancing, cycle count, isolation resistance — then produces an exportable **battery health report**.

Primary targets are the **2018 BMW 330e (F30 PHEV)** and **2025 Cadillac Lyriq (GM Ultium)**, but the design is **vehicle-agnostic**: all vehicle-specific knowledge lives in data (JSON signal sets), not code.

> **Read-only by design.** The app only issues diagnostic *read* requests (UDS `0x22`/`0x19`, J1979 mode 01). It never writes to, codes, or clears any ECU.

## Why it's more than a PID reader

Standard OBD-II (SAE J1979) only exposes generic engine PIDs. Real BMS data lives behind **manufacturer-specific UDS (ISO 14229) service `0x22` "Read Data By Identifier"** requests addressed to the battery ECU, carried over **ISO-TP (ISO 15765-2)** framing. BMW's dealer tool ISTA reads the SME (BMW's BMS) exactly this way. So this app is fundamentally a **UDS-over-ISO-TP client** driven by a per-vehicle signal database.

## Architecture

```
UI (Flutter)            live dashboard · report export · reverse-engineering toolkit
Diagnostics Engine      signal-set loader (OBDb v3) · formula evaluator · battery health model
Protocol layer          J1979 · UDS 0x22/0x19 · ISO-TP (11 & 29-bit)
Transport (DataSource)  ElmBleSource (ELM327+BLE) · BmwCarDataSource (opt) · ReplaySource (tests)
```

The protocol + engine layers are **pure Dart** (no Flutter dependency) so they run under `dart test` in CI without a device or a car. Transport is abstracted behind a `DataSource` interface; a `ReplaySource` plays back recorded captures so the full decode path is testable offline.

## Signal sets

Per-vehicle JSON in [`signalsets/`](signalsets/), using the **[OBDb](https://github.com/OBDb) v3** schema (CC BY-SA 4.0) so existing community definitions can be imported directly. See [`signalsets/signalset.schema.json`](signalsets/signalset.schema.json).

- [`BMW-330e-2018/v01.json`](signalsets/BMW-330e-2018/v01.json) — full SME BMS set, derived from OBDb/BMW-i3s (high confidence; offsets flagged for validation).
- [`Cadillac-Lyriq-2025/v01.json`](signalsets/Cadillac-Lyriq-2025/v01.json) — J1979 baseline plus on-vehicle-confirmed HV signals (pack voltage, battery temps, pack current via ECU 17 `2414`); consolidated DID map in [`docs/lyriq-did-map.md`](docs/lyriq-did-map.md). Per-cell BSM data is gateway-blocked (see Status).

## Hardware

A generic ELM327 BLE clone works for the BMW SME PIDs. For the **Lyriq (29-bit CAN, multiframe ISO-TP)** a genuine STN-based adapter (**OBDLink CX/MX+**) is strongly recommended — most clones can't reliably reach the Ultium battery data. The app abstracts the adapter and surfaces an upgrade recommendation when it detects the clone can't complete 29-bit multiframe reads.

## Prior art & credits

- [OBDb](https://github.com/OBDb) — community signal database & schema (CC BY-SA 4.0)
- [iternio/ev-obd-pids](https://github.com/iternio/ev-obd-pids) — ABRP PID lists & formula semantics (Apache-2.0)
- [JejuSoul/OBD-PIDs-for-HKMC-EVs](https://github.com/JejuSoul/OBD-PIDs-for-HKMC-EVs) — reference EV BMS reverse engineering
- [Ircama/ELM327-emulator](https://github.com/ircama/ELM327-emulator) — offline test harness

## Running it

```
flutter pub get
flutter test           # 54 tests, no device needed
flutter run            # on a connected iOS/Android device
```

No adapter or car? Tap **"Try demo mode (no adapter)"** on the home screen — a
built-in `SimulatedBmwSource` feeds synthetic SME responses through the real
decode pipeline so the dashboard, report, and PDF/CSV/JSON export all work.

## Status

Working end-to-end in software **and validated on-vehicle** for the Cadillac
Lyriq's core HV signals. Detailed, current state lives in
[`docs/lyriq-did-map.md`](docs/lyriq-did-map.md) and
[`docs/on-vehicle-validation.md`](docs/on-vehicle-validation.md).

Done and tested (offline): ISO-TP + UDS + J1979 protocol layer · DoIP/ENET
transport · OBDb-format signal engine · battery-health model + PDF/CSV/JSON
report · coulomb-counting capacity test (charge sessions) · time-series logging
· reverse-engineering DID scanner + correlation identification · BLE transport
(`flutter_reactive_ble`, with clone-adapter workarounds) · Flutter UI (connect /
dashboard / report / capacity / scanner / terminal) · two-vehicle garage
dashboard · BMW CarData scaffold (feature-flagged).

Confirmed on-vehicle:
- **Cadillac Lyriq** — pack voltage, battery temperatures, and pack current
  (ECU 17, DID `2414`) confirmed; usable capacity measured at ~100% SoH via the
  coulomb-counting capacity test; dynamics + odometer signals added. Confirmed
  signals contributed upstream as
  [OBDb/Cadillac-LYRIQ#14](https://github.com/OBDb/Cadillac-LYRIQ/pull/14).
- **BMW 330e** — transport and standard J1979 PIDs confirmed working; the SME
  (BMS) does **not** respond over the standard OBD port, so the SME signal set
  remains inferred/unvalidated.

Known hard limits (proven on-vehicle, not fixable in software):
- The Lyriq's central gateway **filters UDS requests to ECU CB** (Battery
  System Manager) while bridging its J1979 traffic — so per-cell BSM data needs
  bus access behind the gateway, not a better adapter. A hidden ECU `53` exists
  but is security-locked. See the root-cause analysis in
  [`docs/lyriq-did-map.md`](docs/lyriq-did-map.md).
- BMW SME data will likely require a BMW-specific access path (e.g. ENET/DoIP
  or BMW CarData) rather than generic OBD-port UDS.
