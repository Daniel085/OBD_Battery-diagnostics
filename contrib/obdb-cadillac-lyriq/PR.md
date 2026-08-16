# Add confirmed HV-battery signals for the 2025 Cadillac Lyriq

## What this adds

The `signalsets/v3/default.json` for `OBDb/Cadillac-LYRIQ` is currently empty and
the battery DIDs are listed as documented-but-uncaptured. This PR adds **13
signals captured and validated on a real 2025 Lyriq** (VIN `1GYKPTRL5S…`), each
with test cases from actual on-vehicle responses:

| Signal | ECU · DID | Formula | Validation |
| --- | --- | --- | --- |
| `CADILLAC_HVBAT_A` **(pack current)** | DA17 · `222414` | s16 ÷ 20 → A, − = charging | −22.75 A steady at a 9.22 kW AC charge; +0.9 A aux draw in Ready; live jitter. Bolt `7E1.222414` crossover. |
| `CADILLAC_HVBAT_NOMINAL_V` | DA17 · `222429` | u16 ÷ 64 → V | Constant 352.1 V at 70%-charging AND 80%-Ready → nominal rating, not live. Copies at `2428/242D/2434/2489`. |
| `CADILLAC_ODOMETER` | DA40 · `22448F` | u32 ÷ 64 → km | 2,031,186/64 = 31,737 km = 19,720 mi — matched the dash exactly. (`22415B` is the same register.) |
| `CADILLAC_EVSE_PILOT_A` | 7E4 · `224149` | u16 ÷ 10 → A | 38.8 A plugged into a 9.2 kW EVSE; snaps to 10.0 A default on unplug. |
| `CADILLAC_HVBAT_GRP1_V`..`GRP3_V` | 7E4 · `22416C/D/E` | u16 ÷ 100 → V | ~51 V groups; move with charge/load; read 0 when vehicle off (live, behind contactors). |
| `CADILLAC_HVBAT_TEMP` | 7E4 · `22434F` | byte − 40 → °C | Matches the ÷32 temp cluster. |
| `CADILLAC_HVBAT_TEMP_A/B` | 7E4 · `224127/224124` | u16 ÷ 32 → °C | Pack temp sensors. |
| `CADILLAC_HVBAT_COOLANT_T1/T2` | 7E4 · `2240E5/2240E6` | u16 ÷ 32 → °C | Rose under charge (coolant loop). |
| `CADILLAC_LV_RAIL_V` | DA1D · `2233E5` | byte ÷ 10 → V | See correction below. |

## ⚠ Correction to existing documentation: `2233E5` is NOT pack voltage

`command_support` attributes `DA1D.2233E5` as HV pack voltage. On this vehicle it
is the **12 V rail (÷10)**: it answers on ECUs 17/1D/28 with 13.1/13.3/13.9 V
under DC-DC float, and does not move when pack voltage changes (charging 70→80%).
This PR ships it as `CADILLAC_LV_RAIL_V`.

## What is NOT reachable via the OBD port (tested extensively)

- **SOC, live pack voltage, per-cell voltages, capacity registers** — on the
  gateway-blocked BSM (`DACB`) and cell-monitor ECUs. All 256 physical 29-bit
  addresses probed; 11-bit (`7E0-7E7`) is entirely gateway-filtered on this car.
- Bolt BECM capacity/SOC DIDs (`41A3`, `8334`, `43AF`, `4531`, `43A5`) → NRC
  0x31 in every vehicle mode. The Bolt crossover is partial only.
- `224368–436C`/`224373` (charging block) → NRC 0x31 even during AC charging;
  presumed DC-fast-charge-only.
- Note: register availability is wake-mode-dependent — unattended AC charging
  leaves the BECM in a sparse mode where many DIDs freeze or read zero.

## How it was validated

29-bit CAN (ISO 15765-4, `ATSP7` forced — auto-detect fails), ELM327-class
adapter via a Raspberry Pi BLE bridge. Formulas confirmed by state transitions:
charge start/stop/unplug sequences, two metered charge sessions (9.22 kW AC,
cutoff-to-cutoff 70→80%: coulomb-count gave 292 ± 8 Ah ≈ 100% of the 102 kWh
rating, validating the approach), dash cross-checks for odometer and SOC, and
sign checks on current in both directions. Full RE log and raw captures
available on request.
