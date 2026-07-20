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
- [`Cadillac-Lyriq-2025/v01.json`](signalsets/Cadillac-Lyriq-2025/v01.json) — J1979 baseline only; HV BMS DIDs are **not yet reverse-engineered** (29-bit CAN; needs the RE toolkit + ideally an STN adapter).

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

Working end-to-end in software; on-vehicle validation is the remaining step.

Done and tested (offline): ISO-TP + UDS + J1979 protocol layer · OBDb-format
signal engine · BMW-330e-2018 signal set · battery-health model + PDF/CSV/JSON
report · time-series logging · reverse-engineering DID scanner + correlation
identification · BLE transport (`flutter_reactive_ble`) · Flutter UI (connect /
dashboard / report / scanner) · BMW CarData scaffold (feature-flagged).

Needs hardware to finish:
- BMW 330e — validate the inferred cell/temperature bit offsets against a real
  SME (values are trustworthy only after this).
- Cadillac Lyriq — discover the Ultium HV-BMS DIDs on the 29-bit bus with the
  in-app scanner (ideally an OBDLink CX/MX+); the J1979 baseline works today.

Native device build here was blocked only on local toolchain setup (a JDK for
Android; `sudo xcode-select` at Xcode.app + CocoaPods for iOS) — not on any code
issue. `flutter analyze` is clean and all tests pass.
