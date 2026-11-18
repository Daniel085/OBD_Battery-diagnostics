# If we ever write to the car: candidates and guardrails

**Status: parking lot. Nothing here is implemented, and the read-only rule in
`CLAUDE.md` still stands** (the app sends UDS `0x22`/`0x19` and J1979 mode 01,
nothing else). This note records what would become possible, and what it
would take, if we get comfortable enough to go further. Written 2026-11-15.

Most candidates come from the BMW i3 job data published in the OVMS
`vehicle_bmwi3` component (`ecu_*_defines.h`, generated from EDIABAS files).
OVMS itself skips everything that takes arguments, so the ids below are known
but the **argument formats are not**. None of this has been tried on the 330e.
The Lyriq has no candidates: its battery ECU is behind the gateway and ECU 53
is security-locked.

## 1. Reads that need more than service 0x22 (changes nothing in the car)

The best value for the least risk. These are still reads, but they use
RoutineControl (`0x31`) with arguments, the same service that starts
actuators, so they need an allow-list by routine id.

| ECU | Id | What | Why we want it |
|---|---|---|---|
| SME `07` | `AD6E` | cell voltages (`ZELLSPANNUNG_LESEN`) | the open "per-cell DID" item: our sweeps found no per-cell block under `0x22`, and on the i3 it is a routine |
| SME | `AD6D` | module temperatures | per-module view |
| SME | `AD77`, `AD78` | minimum capacity and maximum resistance factor per module | per-module SoH, would test the `DFAA` hypothesis |
| SME | `AD6F`–`AD71`, `AD74`, `AD7C` | per-module histories, per-cell delta SoC | ageing detail |
| SME | `AD79`, `AD7A` | cell-pack status, safety-box replacement count | service history |
| EME `3A` | `DEA1`, `ADFC`, `DEAE` | charge history records and histogram | past charge sessions |
| EME | `ADF9`, `DEB2`, `DEB3` | DC-DC histograms | 12 V charging history |

Also in this class: an extended diagnostic session (`0x10 03`) with tester
present (`0x3E`), in case some identifiers only answer there. Not for the
Lyriq's ECU CB: sessions are proven not to help there.

## 2. Measurements the car runs on request

These operate hardware or run a procedure, and may change what the BMS stores.

| ECU | Id | What | Note |
|---|---|---|---|
| SME | `AD61` | internal isolation measurement, contactors open | fills the third value of `DD6A`, which reads 0 / not plausible today |
| SME | `AD66` | capacity determination (workshop capacity test) | the BMS's own SoH ground truth; results in `D6CC` / `E5F3`. By default the result is taken over into the SoH estimator (`6526` = 1), so this **changes the reported SoH**. Preconditions unknown |
| SME | `AD6B`, `AD75` | start cell balancing | the BMS already balances on its own |
| EME | `ADC0`, `ADC1`, `DF45` | start / stop charging, charge-current setting | would allow "stop at 80 %", which the 330e does not offer. i3 ids; unknown here |

## 3. Writes to stored data

| What | Where | Note |
|---|---|---|
| Clear fault memory (`0x14`) | any ECU | the feature people expect from an OBD app. Destroys evidence and resets emissions readiness monitors (inspection consequences) |
| Register a new 12 V battery | DME / body controller | needed after a 12 V replacement so charging adapts; relevant now that we read the 12 V history. Not in the OVMS i3 files; needs BMW job data |
| Clear 12 V histories | DME `AE02`, `AE03`; body controller `A099` | only meaningful together with a registration |
| Reset SME histories and counters | SME `DF78` and others, `DDEA`, `DDCC` | no use for a diagnostics app |

## 4. Never

Anything that changes what the BMS believes or bypasses its protection. For
an app whose product is a trustworthy battery report, these would falsify the
report as well as risk the pack:

- SoC recalibration (`DD78`), SoH adaption (`D4C6`), reference capacity
  (`DDB7`), NV data reset (`651F`), taking over capacity-test results
  (`6525`).
- Contactor control and enables (`DD61`, `651B`, `6506`–`6508`), HV system
  on/off (`DE02`, `ADF2`), voltage / current / SoC limits (`6500`–`650B`),
  test-bench mode (`651C`).
- Parking lock, rotor-position sensor teach-in, hardware calibration, serial
  number, flashing (`AF43`, `F000`, `400C`–`400F`).
- Security access (`0x27`) by guessing or brute force. If an operation needs
  a seed/key we do not legitimately have, that is the stop sign.

## What it would take

- **Arguments first.** Get the real job definitions (EDIABAS SGBD / ISTA
  data) instead of guessing bytes. A wrong argument to `0x31` is not a read.
- **Data, not code, and kept apart from reads.** A separate `actions` section
  in the signal set (ECU, service, id, arguments, preconditions), validated
  by schema, so nothing in `commands` can ever write and the poll loop cannot
  reach an action.
- **Allow-list in the protocol layer.** Today the engine can only build
  `0x22`/`0x19`/mode 01. Any new service gets an explicit per-id allow-list,
  with a test that everything else is refused.
- **Preconditions checked from live reads:** parked, not charging (or
  charging, as the job requires), 12 V above a floor, HV state as required.
- **One action, one confirmation,** showing the ECU and what will change;
  never in the background, never retried automatically.
- **Before/after capture** saved for every action, and a replay test of the
  exchange before it is ever sent to the car.
- **Off by default,** behind a setting or a separate build, so the build
  that reads cannot write. Shared signal sets (OBDb upstream) stay read-only.
- **Order to try, if ever:** per-cell voltages (`AD6E`), then the other
  routine reads, then clear fault memory, then 12 V registration. Section 2
  only with BMW's preconditions in hand.
