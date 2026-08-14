# Add confirmed HV-battery signals for the 2025 Cadillac Lyriq

## What this adds

The `signalsets/v3/default.json` for `OBDb/Cadillac-LYRIQ` is currently empty and
the battery DIDs are listed as documented-but-uncaptured. This PR adds **9
HV-battery signals captured and validated on a real 2025 Lyriq** (VIN
`1GYKPTRL5S…`), each with a test case whose expected value the signal's own
formula reproduces exactly:

| Signal | ECU · DID | Formula | Notes |
| --- | --- | --- | --- |
| `CADILLAC_HVBAT_V` | 7E4/7EC · `2233E5` | 8-bit × 2.7 → V | ~356 V @ ~49% SOC |
| `CADILLAC_HVBAT_GRP1_V`..`GRP3_V` | 7E4 · `22416C/D/E` | u16 ÷ 100 → V | ~51 V groups; moved 51.14→50.98 V on charge stop |
| `CADILLAC_HVBAT_TEMP` | 7E4 · `22434F` | byte − 40 → °C | matches the temp cluster |
| `CADILLAC_HVBAT_TEMP_A/B` | 7E4 · `224127/224124` | u16 ÷ 32 → °C | pack temp sensors |
| `CADILLAC_HVBAT_COOLANT_T1/T2` | 7E4 · `2240E5/2240E6` | u16 ÷ 32 → °C | rose under charge (coolant loop) |

## How it was validated

Read over the OBD-II port with an ELM327-class adapter, 29-bit CAN (ISO 15765-4,
`ATSP7`); ECU 40 (11-bit `7E4`/`7EC`) is the propulsion/battery controller.
Formulas were confirmed by **charge/idle correlation** — e.g. the group voltages
rose under a 3.45 kW charge and fell when it stopped; the coolant temps rose
under charge. Full RE log and captures available on request.

## Important addressing note

`7E4`/`7EC` (11-bit) and `18DA40F1`/`18DAF140` (29-bit) address the **same**
battery controller; the responses in the test cases are shown with the 29-bit
response id `18DAF140` as captured. `fcm1: true` is set for the multi-frame flow
control.

## What is NOT included (and why)

- **SOC** (`DACB.222B43` / `2227C6`) and **per-cell voltages** (`DACB.222AF5`):
  the BSM (ECU CB) is reachable for J1979 (`0100`) but the vehicle gateway
  **filters UDS `22xxxx` requests** to it over the OBD port — confirmed by CB
  answering `0100` but never `22F190`. These need bus access behind the gateway
  (e.g. DoIP), so they are left as documented-but-uncaptured here rather than
  guessed.
- **Pack current** — not yet located in a confirmed DID.

## Model year

Captured on a **2025** Lyriq, so the test cases live under
`tests/test_cases/2025/`. This matches `generations.yaml`, which places 2025 in
the "Gen 1 Refresh" generation (2025→), separate from 2023–2024. The battery
hardware is unchanged between the years (same BEV3 platform, same 102 kWh Ultium
pack and electrical architecture), so these DIDs/formulas are expected to apply
to 2023–2024 as well — but they are only *verified* on a 2025 here, and labelled
accordingly.

## Provenance / license

Signals are original on-vehicle captures contributed under the repo's CC BY-SA
4.0. Cross-referenced with the existing `command_support.yaml` (which lists
`7E4.7EC.22434F` and `224181-224240` in its uncaptured section).
