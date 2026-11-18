# BMW 330e — SME (HV battery manager) access

## Status: SME READ ON-VEHICLE (2026-11-08)

The SME answers on the plain OBD port at extended address **07**
(`6F1` -> `607`), with the same Viecar ELM327 v2.2 clone BimmerLink uses. Raw
log: `captures/bmw_sme_2026-11-08.txt`. Signal set: `signalsets/BMW-330e-2018/v02.json`.

| DID | Raw (round 1) | Decoded | Check |
|---|---|---|---|
| `DDBC` | `038B 030C 00F6` | SOC 90.7 %, window max 78.0 %, window min 24.6 % | BimmerLink bounds 78 / 25 ✓ |
| `6335` | `00 00 00 53` | SOH **83 %** (i3 layout, byte 3) | no ground truth (BimmerLink paywall) |
| `DD69` | `FFFFFF6C` | pack current −1.48 A raw (s32 /100; raw sign is **+charge**, see below) | BimmerLink −1.28 A parked ✓ |
| `DDC0` | `063F 06A3 0655 01` | cell temp min/max/avg 15.99 / 16.99 / 16.21 °C | ambient 15.5 °C ✓ |
| `DFA0` | 62 bytes | see layout below | ✓ ranges |
| `DD66` | `7B5F` | pack voltage **315.83 V** (u16 /100) | 80 × avg cell 3.9518 = 316.1 V ✓; BimmerLink 317 V 15 min earlier |
| `DD68` | `7F 22 31` | requestOutOfRange: i3 pack voltage is **not** on the F30 SME | |
| `F190` | 20 bytes | VIN WBA8E1C51JAXXXXXX | matches BimmerLink ✓ |

`DFA0` layout (F30; the i3 layout does NOT apply). Six `[min, max, avg]` u16
triples, then a trailer:

| Bytes | Values | Meaning |
|---|---|---|
| 0–5 | 2364 / 2460 / 2424 | unknown |
| 6–11 | 39669 / 39760 / 39724 | cell voltage /10000 → 3.9669 / 3.9760 / 3.9724 V |
| 12–17 | 1599 / 1699 / 1621 | cell temp /100 °C (same as `DDC0`) |
| 18–23 | 14881 / 18731 / 16235 | unknown (wide spread; resistance? per-cell Ah?) |
| 24–29 | 7144 / 7447 / 7342 | cell SoC /100 → 71.44 / 74.47 / 73.42 % |
| 30–35 | 39880 / 39930 / 39904 | a **second** cell-voltage triple (3.988 / 3.993 / 3.990 V) |
| 36–61 | `41E9 3E32 DFD5 39AF 610A 0014 0320 0001 … 0001 2F82` | unknown; `610A` moves between reads |

v02 maps `HVBAT_CELL_V_*` to bytes 6–11, the **live** triple: across four
reads it moved (min 3.9669 → 3.9546 V while idling), while bytes 30–35 stayed
identical every time (3.9880 / 3.9930 / 3.9904). The 30–35 triple is a stored
snapshot (last rest/OCV?), as are bytes 0–5 and 18–23. Bytes 44–45 change on
every read (`610A`, `61AB`, `75CB`): a counter or timestamp?

### Current sign (corrected 2026-11-14)

The SME reports **charge as positive, discharge as negative**: raw −1.48 A
running and parked (2026-11-08), raw +11.02 A while plug-in charging at
~3.2 kW (2026-11-13, `captures/bmw_chg_2026-11-13.txt`). BimmerLink shows the
same raw sign. The app's `HVBAT_CURRENT` convention is the opposite (positive
= discharge, negative = charge/regen, as on the Lyriq), so the v02 signal set
negates the raw value (`mul: -1`). Before this fix drive mode showed REGEN for
a stationary car in Drive, and the dashboard and capacity test would have
read a plug-in charge as a discharge. Raw values in this document and in the
probe output keep the SME's own sign.

### Same-moment check vs BimmerLink (2026-11-08, car running)

Our read 13:47 (Pi clock) vs BimmerLink screenshots 1:49–1:50 pm:

| | ours | BimmerLink |
|---|---|---|
| cell V min / avg / max | 3.9546 / 3.9626 / 3.9669 | 3.952 / 3.960 / 3.965 |
| cell V spread | 12.3 mV | 13 mV |
| displayed SoC | 89.6 % | 89 % |
| current | −1.51 A | −1.52 A |
| window bounds | 24.6 / 78.0 | 25 / 78 |
| pack voltage | (no DID yet) | 317 V |

Agreement within 2–3 minutes of drift, so `HVBAT_CELL_V_*` (DFA0 bytes 6–11),
`HVBAT_SOC`, `HVBAT_CURRENT` and the window bounds are confirmed against an
independent tool. BimmerLink's per-cell chart shows ~96 slots with the last ~16
empty: **80 cells in series** (317 V ÷ 3.959 V ≈ 80). The chart also means a
per-cell voltage DID exists on the SME.

The Viecar takes ONE Bluetooth connection: close BimmerLink (or turn off the
phone's Bluetooth) before running the Pi probe, or it fails with
"FAILED to connect to adapter".

## Why it failed before (Aug 2026)

BMW F/G-series ECUs use ISO 15765-2 *extended addressing*: the first CAN data
byte is the target address and the ISO-TP PCI comes **after** it.

| | bytes on the wire |
|---|---|
| correct request (6F1) | `07 03 22 DD BC` |
| response (607) | `F1 10 09 62 DD BC ..` (F1 = tester) |
| flow control (6F1) | `07 30 00 00` |
| Aug: `0722DDBC`, CAF on | `04 07 22 DD BC` (ELM's PCI first) |
| Aug: `0722DDBC`, CAF off | `07 22 DD BC` (no PCI) |

No ECU answers those, so the Aug `NO DATA` said nothing about reachability.

## Adapter recipe (proven on the Viecar clone)

`ATCAF1, ATCEA07, ATFCSH6F1, ATFCSD07300000, ATFCSM1, ATAT0, ATSTFF`, then send
plain `22xxxx`. Implemented in `extendedAddressingCommands()`
(`lib/transport/elm327_protocol.dart`). What the probes showed:

- `ATCAF0` + manual `07 <PCI>` framing: requests work, but the clone sends **no
  flow control**, so only the First Frame arrives (probe 2 E1).
- `ATCEA07`: the clone inserts the address on requests, but its default flow
  control lacks it. A custom FC data `07300000` fixes it (E4). With `300000`
  it doesn't (E3), so the clone does not prefix FC data itself.
- Manually sending `07 30 00 00` right after the First Frame also works (E2).
- The SME often answers `7F 22 78` (response pending) first. With adaptive
  timing the adapter gives up too early and the reply lands on the *next*
  request. `ATAT0 ATSTFF` fixes it; `responseDataFields()` drops the pending frame.
- A functional `DF` census got only `610` (the gateway, ZGW). Physical census
  still to do (probe 1's census used `ATAR`, which filters the wrong id for
  `6F1`, so it is invalid).

## DD00–DDFF sweep (2026-11-08)

44 DIDs answered (full list in the capture). Voltage-related:
- `DD66` = 315.83 V (/100) → `HVBAT_VOLTAGE` in v02.
- `DDB4` = 315.79 V (/100): a second HV voltage within 0.05 V. Pack-side vs
  link-side (across the contactors) unknown; would separate when contactors open.
- `DDEF` = 315 (integer volts).
- `DDE9` / `DDEC` contain 3.968 V (/10000) fields, probably cell min/max
  snapshots; no 80-entry per-cell block in this range.

Other likely-interesting, undecoded: `DDBE` (10 u16, looks like temperatures
0x42–0x46 then 0x0708/0x0640 limits), `DDC2`, `DDC6`, `DDC8` (5 × 0x014B),
`DDCA` (ASCII "9130810097": a serial/part no.), `DD7C`, `DD8E`, `DD90`, `DD91`
(counters/histograms?).

## DF00–DFFF sweep (2026-11-08)

44 DIDs answered (full list in the capture). **No live per-cell block** (no run
of ≥16 values at 3.90–4.00 V under any scale in `DD00–DFFF`). Leads:
- `DFA9` = 5 × s16/100 temperatures (16.66–17.00 °C) then 6 × `7FFF` (not
  fitted); `DFAA` and `DFAD` likewise have 5 real entries of 11. Together with
  80 cells this suggests **5 modules × 16 cells**. Published sources agree:
  80 cells in five modules (WhichCar), and BMW TSB MC-10149255 lists five cell
  supervision circuits (DTCs 21F0C2–21F0C6). BimmerLink's "Module 1–11" grid
  matches the SME's **11-slot** per-module arrays (the firmware's maximum),
  not the number of modules fitted; slots 6–11 read `7FFF`/`FF` (not fitted).
- `DFCA` = ten 5-byte records `<u16 mV> <u16 mV> 41` (4126/4078, 4149/4085, …,
  3702/3686 …): stored cell max/min voltage pairs, probably at past charge/discharge
  ends. `DFCB` looks related.
- `DFA8` = 140 bytes, all zero: per-cell flags (balancing?) candidate.
- `DFC8` = 5 × u16/20 V (314.7, 323.3, 317.3, 303.0, 284.1): pack-voltage stats?

## Cycle-count candidates (unvalidated)

Values from the 2026-11-08 sweeps (odometer 77,698 km, car ~8.5 years old):

| DID | Value | Hypothesis |
|---|---|---|
| `DFAC` | u32 2198, 1569 | event counters: drive/power-up cycles? plug-in charge sessions? |
| `DF67` | u32 9,013,147, 22,197,916 | lifetime charge totals in/out (mAh → ~9,013 / 22,198 Ah ≈ 350 / 850 equivalent full cycles of 26 Ah; or Wh) |
| `DF62` | u16 925 | counter? |
| `DF60` | u32 10594, 78034 | **hours** with HV on / total (i3 layout, see below): 78,034 h = 8.9 years |
| `DD8E`, `DD90`, `DD91`, `DF66`, `DF76` | count arrays | histograms (temperature/SoC/current bins?) |

Validate with a before/after read around ONE event:
`python3 sme_probe.py --read DFAC DF67 DF62 DF60 DD8E DF76 DFAA DFAD DFE2 DDC9`.
After one plug-in charge, a session counter rises by exactly 1 and a charge
total rises by the energy added (a 3 kWh top-up ≈ 9.5 Ah at 317 V: +9,500 if
mAh, +3,000 if Wh). After one drive, a drive counter rises and charge counters
don't.

## Ageing and lifetime figures from the i3 layout (2026-11-15, UNCONFIRMED)

The OVMS `vehicle_bmwi3` component publishes the i3 SME's EDIABAS job data
(`ecu_sme_defines.h`). Decoding the 2026-11-08 sweeps with those layouts:

| DID | i3 meaning | Decodes to | Verdict |
|---|---|---|---|
| `DF60` | hours with contactors closed / total battery life | 10,594 h / 78,034 h | fits: 78,034 h = 8.9 years, a pack that started counting in late 2017 (the `DFE2` clock says the same) |
| `DDB6` | internal-resistance ageing, `u16 / 10` %, R_new / R_now × 100 | 62.8 % | plausible next to 83 % capacity; no ground truth |
| `DD6A` | isolation resistance kΩ: after-run, in operation, internal; then 3 plausibility flags | 2000, 2000, 0; flags 1, 1, 0 | plausible; 2000 looks like the ceiling. Internal is only measured by a routine (not run) |
| `DD63` | contactor switchings without load / under load (u32 each) | 15,403 / 0 | same order as `DF63` = 14,080 (i3: terminal cycles) |
| `DD7D` | current limits, `u16 / 10` A charge, discharge | 150 A / 280 A | plausible |
| `DD7E` | voltage limits, `u16 / 100` V charge, discharge | 331.64 V / 224.84 V | plausible (4.15 V and 2.81 V per cell × 80) |
| `DD6C` | coolant circuit temperature, `u16 / 100` | 16.8 °C | matches cell temps 16–18 °C that day |
| `DD73`, `DD74` | lifetime charge / discharge, `u32 / 3600` Ah | big-endian: 754,197 / 154,794 Ah (impossible) | **little-endian** gives 34,021 Ah in / 33,136 Ah out. `DD73` confirmed by the 2026-11-15 charge (below); the `DF67` reading above is not a charge total |
| `DD8E` | cycle history | — | i3 layout does not fit (36 bytes here) |

In the app (v02 signal set, group `health`, units marked `?`, read every
5 minutes via `freq`): `DDB6` → `HVBAT_SOH_RESISTANCE`, `DD6A` →
`HVBAT_ISOLATION` (the in-operation value), `DF60` → `HVBAT_HV_ON_HOURS` /
`HVBAT_AGE_HOURS`, `DD63` → `HVBAT_CONTACTOR_CYCLES` / `_LOAD`. The report
lists them as metrics marked "(unconfirmed)" and does not grade them.
To confirm: a second tool showing the same figure (ISTA, BimmerLink paid
tier), or for the counters a before/after read (hours +1 per hour of HV on,
contactor count + ~2 per drive).

Still to try from the same file: `6334` (resistance ageing, alt.), `D6CF`
(per-CSC temperatures), `DDBF` (cell V min/max), `D6CC` (results of the last
3 workshop capacity tests). `DD76` (12 V supply at the pack) answers
`7F 22 31` on this car.

### Second read, 2026-11-15, car plugged in and charging

`captures/bmw_2026-11-15.txt` (12:26–12:29, minutes after a drive, charge
just started at 9 % displayed SOC, 11.2 A). J1979 is silent in this state but
the SME, the DME and the EME all answer UDS. Replay test:
`test/bmw_charging_capture_test.dart`.

| DID | 2026-11-08 | 2026-11-15 | What that shows |
|---|---|---|---|
| `DF60` total hours | 78,034 | 78,200 | **+166 h in 166 h of wall-clock time: a running hour counter. Confirmed**; `HVBAT_AGE_HOURS` lost its `?` |
| `DF60` contactors-closed hours | 10,594 | 10,600 | +6 h for a week with 55 km of driving and at least one charge. Plausible; this charge's log reads it before and after, which checks it to the hour |
| `DD63` contactor switchings | 15,403 / 0 | 15,435 / 0 | +32 in a week (a few per drive or charge); still none under load |
| `DDB6` resistance health | 62.8 % | 62.7 % | moves slowly, as an ageing figure should; warmer pack today (21–25 °C vs 16–17 °C) |
| `DD6A` isolation | 2000 / 2000 / 0 kΩ | identical | still at the ceiling |
| `DD73` charge in (little-endian) | 34,021 Ah | 34,049 Ah | see below |
| `DD74` charge out (little-endian) | 33,136 Ah | 33,173 Ah | out rose more than in (+37 vs +28 Ah), and the pack is emptier than on 11-08 |
| `DD7D` current limits | 150 / 280 A | 142 / 280 A | charge limit moves with state, as a limit should |
| `DD6C` coolant circuit | 16.8 °C | 21.1 °C | tracks the cell temperatures (21–25 °C) |

`DD73` live: `08 5C 4E 07` at about 12:27:07 and `0F 64 4E 07` at 12:30:04.
Little-endian that is +2,055 A·s in ~177 s at 11.2 A; `DD74` did not move.

### The charge of 2026-11-15: counters confirmed, capacity measured

`captures/bmw_chg_2026-11-15.txt` (`sme_chglog.py` on the Pi): plugged in at
~12:25 at 9.0 % SOC (`DDBC`), charge ended by itself at 14:03:28 at 90.7 %,
contactors open at 14:03:54. Current every ~26 s, counters every ~10 min.
Two short pauses (12:37–12:44, 12:45–12:46) for the DME reads; unbroken from
12:47. Charge rate 11.2 → 9.7 A (3.3 → 3.1 kW DC), tapering from 13:30 at
4.06–4.09 V per cell. Pack 22.6 → 26.5 °C. Replayed in
`test/bmw_charging_capture_test.dart`.

**`DD73` is the charge-in counter: ampere-seconds, u32 little-endian.**
12:47:05 → 13:59:51 it rose 34,487 A·s; the integrated `DD69` current over
the same span is 34,461 A·s (0.08 % apart, every 10-minute step within
1.2 %). `DD74`, the matching discharge counter, stood still. Both are now in
the signal set (`HVBAT_AH_CHARGED`, confirmed; `HVBAT_AH_DISCHARGED`, `?`
until it is seen counting on a drive), using the new `"le": true` format
option. Lifetime: 34,049 Ah in, 33,173 Ah out at 77,753 km. The counter
includes regen, so it is not a count of plug-in charges.

**Capacity: 16.2 Ah per 100 % of SOC.** `DDBC` SOC against integrated
current gives 16.21 Ah / 100 % in the constant-current part, 16.2 in the
taper and 16.21 overall: the SOC figure is linear in charge. In energy,
3.89 kWh went in between 13.0 % and 90.7 %, i.e. 5.0 kWh per 100 %
(charging side, at the pack terminals).

What that says about the 83 % SOH (`6335`): BMW rated the pack at 5.7 kWh
usable when new. 5.0 / 5.7 = 88 % measured on the way in; what comes back
out is a few percent less. In charge: 5.7 kWh at the ~293 V nominal is
19.5 Ah, and 16.2 / 19.5 = 83 %. So the measurement lands on 83–88 %
depending on how the as-new figure is converted. **It supports the 83 %; it
cannot prove it to the percent** without BMW's as-new Ah figure.

**Cycles.** No confirmed cycle counter has been found on the car (`DFAC`
2201 and `DF62` 926 are slow counters of unknown meaning; the i3's cycle
history `DD8E` does not fit). The app computes **equivalent full cycles** =
lifetime charge ÷ rated capacity (`pack.ratedAh` = 26 Ah in the signal set):
34,049 Ah in → **~1,310**; on the discharge side 33,173 Ah → ~1,276. The
throughput includes regen and hybrid-mode cycling, so this measures wear, not
plug-in charges. Other yardsticks for the same throughput: ~1,180 against
the BMS's own 100 % (28.8 Ah per 100 % cell SoC, measured in this charge),
~2,050 against today's usable window (16.2 Ah).

**Why 26 Ah, and why only 16 Ah is usable.** 26 Ah is the rated capacity
of the cells: BMW's press data gives 7.6 kWh gross at 293 V (= 25.9 Ah),
BMW training material says the cell capacity went "from 26 Ah to 34 Ah" with
the next pack generation, and BMW's EU battery-regulation sheet quotes the
later 330e pack at a rated 34.0 Ah, i.e. the cell rating. No F30 document
stating 26 Ah outright was found (web search, 2026-11-15). The car does not
use the whole cell: BMW's own figures are 5.7 kWh usable of 7.6 (75 %) when
new, and the SME reports the window it uses today as 24.6–80.5 % of cell
SoC. So of the gap between 26 Ah and the measured 16.2 Ah, the buffer BMW
keeps at both ends is the larger part and ageing the smaller (19.5 Ah
usable when new → 16.2 Ah now). Unexplained: on the SME's own cell-SoC
scale this charge works out to 29 Ah per 100 %, more than the rating, so
that scale is not simply "percent of 26 Ah".

In the app the cycle count is in the report (`equivalent_full_cycles`) and
on the dashboard under the lifetime counters, with a line saying it is
computed and from what.

Other things this log settled:

- `DDBC` SOC is the usable-window SOC: `(cell SoC − 24.6) / (80.5 − 24.6)`
  with the window bounds from the same DID. Cell SoC (`DFA0`, `DFAD`,
  J1979 `015B`) ran 32.7 → 76.4 % while `DDBC` ran 13.0 → 90.7 %.
- A finished charge stops at 90.7 % on this scale, on cell voltage
  (4.08 V), not at 100 %. What the dash shows at that point is not yet known.
- `DFAD` = per-module SoC (32 → 76, all five modules together). `DFAA` =
  84, 84, 84, 84, 83 for the whole charge: constant while SoC moves, as a
  per-module SoH should be (85, 85, 85, 84, 83 on 11-08).
- `DF60`: the total-hours word ticked at ~12:34 and ~13:34; the
  contactors-closed word ticked once, at ~13:13, during 1.6 h of charging,
  so one count is 0.8–1.7 h. With +4 in the 48 h before (one logged charge
  plus driving) and +6 in the week, it is treated as confirmed hours:
  `HVBAT_HV_ON_HOURS` lost its `?` later the same day.
- `DFE2` did not change in 1.5 h: it is **not a running clock** but a stamp,
  most likely the time the SME last woke (281,461,323 ≈ 12:25 on 11-15).
  The 11-08 value then puts that day's wake-up at ~12:36, an hour before
  the first capture, which fits.
- `DF67` (9,014,100 / 22,208,297) did not move during 12.6 Ah of charging,
  so it is not a live charge total. It was 9,013,147 / 22,197,916 on 11-13:
  updated between sessions, meaning unknown.
- `DFAC` first word 2201 (2198 on 11-13), `DF62` 926 (925 on 11-13): slow
  counters, a few per day. Could not be read after the charge: the SME
  stops answering the moment the contactors open.

## Per-module data: `DFA6`–`DFAD`, `DFC8` (11 slots, 5 modules)

The SME has a run of DIDs with one entry per module slot. The pack has 5
modules; slots 6–11 read as "absent" (`FF`, `7F FF`) or zero.

| DID | 2026-11-08 | Reading | Status |
|---|---|---|---|
| `DFA6` | `00` × 11 | **status per module, 0 = OK** | 0 = OK confirmed by the owner (2026-11-15, with BimmerLink's "Defective cells" page showing all OK). The meaning of a non-zero code is unknown; none has been seen |
| `DFA9` | 1666, 1700, 1700, 1666, 1700, `7FFF` × 6 | temperature per module, `s16 / 100` °C (cell temps that day: 16.0–17.0 °C) | likely; not in the app |
| `DFAA` | 85, 85, 85, 84, 83, `FF` × 6 | SoH per module, %; the pack SOH `6335` = the lowest | constant through the 2026-11-15 charge (84, 84, 84, 84, 83) |
| `DFAD` | 71, 71, 71, 71, 70, `FF` × 6 | SoC per module, % | followed the 2026-11-15 charge, 32 → 76 |
| `DFAB` | 20 × 11 | unknown | |
| `DFC8` | 6294, 6466, 6345, 6076, 5677, then zeros | unknown (u16 per module) | |

In the app: `DFA6` → `HVBAT_MODULE_1..5_DEFECT` (group `modules`, unit
`code`, every 5 minutes). A 0 is shown as "OK" (`fmt.map` in the signal set).
The report counts modules with a non-zero code (`modules_reporting_defect`)
and raises a warning naming the module and the code.

Not the same thing as stored fault codes. Those are read per control unit
with UDS `0x19` (allowed by the read-only rule), which the app does not do
yet.

## Per-module SoH? Clock and event log (unvalidated)

- `DFAA` = 85, 85, 85, 84, 83, then FF×6 (5 modules of 11 slots). Pack SOH
  `6335` = 83 = the **minimum module**, the usual "weakest module" rule.
  Hypothesis: per-module SoH. Check: it must stay constant while SoC changes.
- `DFAD` = 71, 71, 71, 71, 70 at min cell SoC 70.2 % → per-module SoC.
- `DFE2` bytes 1–4 = u32 280,857,216: an SME **seconds clock**, zero ≈
  mid-Dec 2017 (production / first power-up?). Read during the DF sweep.
  2026-11-15 12:30:05: 281,461,323, i.e. +604,107 s, about 1.5 h more than
  the wall clock allows since that sweep. Either the 11-08 value was not
  "now" (its low byte is `80`) or the clock does not tick evenly. The charge
  log reads it every 10 minutes, which shows whether it runs at 1 s/s.
  Today's `DDC9` also holds two stamps ~15 h *ahead* of it, so `DDC9` may
  not be on this clock (or holds planned times).
- `DDC9` = 5 × 9-byte records `<u32 value> <u32 clock> <flag>`: events
  ~3 h, 20 h, 7.7 d, 9.6 d, 9.7 d before that read, values 5418, 5418,
  2611, 23274, 1408. A short recent-event log; meaning unknown (charge
  sessions?). `DDEB` has more clock stamps (~2–11 days back).
- No SoH-over-time table seen. BimmerLink's "SoH trend vs fleet average" is
  most likely their app storing readings + crowd data, not an ECU history.

## ECU census (2026-11-08)

Physical `22F190` to every target 00–7F (correct ext addressing, rx id 0x600+addr).
**29 ECUs answer:** `01 06 07 08 10 12 14 18 1C 1D 29 2C 2D 30 35 3A 40 43 44
56 5E 5F 60 61 63 67 6D 72 78`. Known: `07` SME, `10` gateway (ZGW), `3A` EME
(BimmerLink labels it "EME (3A)"). `12` is the usual F-series DME address.
Other names unverified.

## EME motor data (address 3A): UNCONFIRMED

Added 2026-11-15 for drive mode (BimmerLink's "Motor" page: two motor
temperatures, RPM, actual and target torque). **Read on the car once, parked
and charging (2026-11-15, below); never with the motor turning.**

The DIDs and layouts are the BMW i3 EME's, from the EDIABAS job data
published in the OVMS `vehicle_bmwi3` component (`ecu_eme_defines.h`). The
i3's EME is at `1A`; the 330e's is `3A` (BimmerLink, census above), so the
request is `6F1: 3A 03 22 DE A6` and the reply comes on `63A`.

| Signal | DID | i3 layout |
|---|---|---|
| Motor temperature 1 / 2 | `DEA6` | `s16 / 64` degC at bytes 0, 2 |
| Motor speed | `DEA7` | `u16 / 2 − 5000` rpm at byte 0 |
| Torque actual / target | `DEA7` | `s16 / 2` Nm at bytes 2, 4 (byte 6: operating mode) |

Other i3 EME DIDs worth trying on the same visit: `DE8C` (power-electronics
temperatures), `DE75` (HV link voltages, `u16 / 5` V), `DE8A` (motor phase
currents).

They are in `signalsets/BMW-330e-2018/v02.json` as `MOTOR_*` with units
marked `?` (shown as read, never converted), and `test/bmw_eme_motor_test.dart`
uses hand-built frames, not a capture. **To confirm**, car in READY and warm:

    python3 sme_probe.py --target 3A --read DEA6 DEA7 DE8C DE75

and compare with BimmerLink's Motor page at the same moment (2026-11-08,
parked warm: 39.7 / 41.7 degC, 0 rpm, 0 Nm). If the SME precedent holds, the
DID may exist with a different layout (`DFA0`) or not at all (`DD68`). On a
match: drop the `?` from the units and "(unconfirmed)" from the names, and
replace the hand-built frames with the capture. A 2026-11-15 morning attempt
from the Pi got NO DATA from every ECU (car asleep or adapter in the other
car).

**2026-11-15 12:28, plugged in and charging, minutes after a drive**
(`captures/bmw_2026-11-15.txt`, `--no-gate`): the EME answers on `63A`.

| DID | Reply | Reading |
|---|---|---|
| `DEA6` | `0D 56 0D D9` | 53.3 / 55.4 °C. Believable for a just-driven motor, and the two sensors sit 2.0 °C apart exactly as in BimmerLink's 39.7 / 41.7. Not a same-moment comparison, so the `?` stays |
| `DEA7` | `00 00 00 00 00 00 0D` | 7 bytes as on the i3. Torque 0 / 0 Nm, mode 13. **Speed field raw 0**, which the i3 formula turns into −5000 rpm |
| `DE8C` | `04 E7 0D 57 0C 65 04 EA` | 8 bytes (i3: 30). As `s16 / 64`: 19.6, 53.4, 49.6, 19.7 °C. Not the i3's order (three inverter phases would be alike); the second value is the motor temperature again |
| `DE75` | `24 A7 24 AA` | i3's `/ 5` gives 1,877 V. `/ 32` gives 293.2 / 293.3 V with the pack at ~294 V: likely the HV link voltages, scale guessed |

Open on `DEA7`: either the EME reports 0 = "no reading" while the inverter is
off, or this car's speed has no −5000 offset. The signal set now drops the
raw-0 value (`nullmin`) so the app never shows −5000 rpm. **One read in Ready
at a standstill settles it:** raw `27 10` means the i3 offset is right, raw
`00 00` means there is none (then remove `add` from `MOTOR_RPM`).

Drive mode reads these every ~4 s between pack-current samples. Each visit
re-addresses the adapter (`ATCEA`, flow control, `ATCRA`) twice, so the power
feed pauses for the duration. Measure that pause on the car ("Sample rate"
on the drive screen) before trusting peak-power figures taken with it on.

## 12 V battery

The IBS (on the 12 V negative cable) only measures voltage, current and
temperature; the **DME computes the 12 V SoH** (from the voltage drop at engine
start) and uses it for start-capability and recharge strategy. No public DID.
Finding it means sweeping the DME (`12`) with `--fast`, matching 14.7 V
(running), capacity in Ah, and % values: **2 min 13 s per 256 DIDs**.

First block, `4000–40FF` (`captures/bmw_dme_2026-11-08.txt`): 52 DIDs answer.
No **live** 12 V voltage. `40E6`/`40E7`/`40E8` hold bytes that read as
14.5/14.6/14.4 V (÷10) followed by 73/74 and 100. That looks like 12 V
records (voltage, SoC?, SoH?), but they were byte-identical over 6 reads in a
minute while `0142` read 14.56 V, so they are stored values, not live ones.
A stored SoH *should* be static, so this stays a lead, unproven.
`00 01 2F 82` = 77,698 km is an odometer stamp (BimmerLink: 48,281 mi) used in
DME records (`4083`, `409D`) and the SME's `DFA0` trailer.

Then `4100–44FF` (8 min, 72 DIDs) and `DD00–DFFF` (6 min, **zero** DIDs; the
DME does not use the range the SME does). A live re-read of the short
`41xx–44xx` DIDs: only `4201` (slow counter) and `4205` changed; nothing tracks
the 14.58 V module voltage. `4204`/`4300`/`4408` look like temperatures in
0.1 K (2886 = 15.5 °C = ambient). `4112` holds date stamps (`07EA 0B 06` =
2026-11-06).

### 12 V recharge history: `409D` / `409E` (2026-11-15, UNCONFIRMED)

The i3's powertrain ECU has a "cyclic recharge" log (OVMS `ecu_edm_defines.h`:
`ZYKLISCHES_NACHLADEN_INFO`, `12V_NACHLADEHISTOGRAMM`): when the car sits, it
tops the 12 V battery up from the HV pack and records it. The 330e's DME
returned the same thing in the 4000–40FF sweep, with a slightly different
record (3-byte km, no forecast byte):

`409D`, 88 bytes = 8-byte header + 4 × 20-byte records, newest first.

| Bytes | Header | | Bytes | Record |
|---|---|---|---|---|
| 0–3 | clock at last park (s, same base as the SME's `DFE2`) | | 0–3, 4–6, 7 | clock, km, 12 V SoC at park |
| 4–6 | km at last park | | 8–11 | clock when the top-up started |
| 7 | 12 V SoC at last park, × 0.5 % | | 12 | 12 V SoC at start, × 0.5 % |
| | | | 13 | ? (i3: HV SoC; does not behave like one here) |
| | | | 14 | 12 V battery temperature, − 128 °C |
| | | | 15–16 | duration, s |
| | | | 17 | 12 V SoC at end, × 0.5 % |
| | | | 18, 19 | ? (i3: HV SoC), end reason (always 5) |

| Top-up | Parked | Odometer | Top-up started | 12 V SoC park → start → end | Temp |
|---|---|---|---|---|---|
| 1 | ~18 Oct, 15:45 | 77,624 km (48,233 mi) | ~24 Oct, 22:36 (6.3 d later) | 79.0 → 66.0 → 73.5 % | 16 °C |
| 2 | ~14 Jul, 07:50 | 76,893 km (47,779 mi) | ~15 Jul, 07:38 (1.0 d) | 70.0 → 66.5 → 68.5 % | 24 °C |
| 3 | ~11 Jul, 00:22 | 76,871 km (47,765 mi) | ~12 Jul, 17:49 (1.7 d) | 66.5 → 59.0 → 68.0 % | 37 °C |
| 4 | ~28 Jun, 11:44 | 76,832 km (47,741 mi) | ~29 Jun, 15:26 (1.2 d) | 64.0 → 65.0 → 68.0 % | 19 °C |

Mileage is exact (the record's own odometer stamp). Dates are the record's
clock stamps, in seconds on the car's running counter, converted with one
anchor: the header's "last park" stamp read on 2026-11-15 is taken as
12:20 that day (parked minutes before the first read). The same conversion
puts the 2026-11-08 header at 13:34, two minutes before that day's first
probe at 13:36, so the counter runs true and the dates are good to well
under a day (clock times are Pi local time, no daylight-saving shift
applied). For reference: boot battery registration stamp 77,690 km
(48,274 mi), today 77,753 km (48,313 mi).

Header: last park at 77,698 km (the odometer that day) with 12 V SoC 99.5 %.
Every top-up ran ~3,600 s. `409E` = 8 bins of "days parked before the top-up"
(≤2: 6, 2–4: 3, 4–6: 1, 6–10: 1, 10–14: 2, 14–21: 2, 21–28: 4, >28: 4) and
8 bins of duration (all 23 in the longest); both total **23 top-ups** in the
car's life.

Why this is believed: clocks ascend and sit on the SME's clock base, km
stamps match the odometer, temperatures fit the season, both histograms total
23. Why it is still unconfirmed: no second tool has shown these numbers, and
"SoC" could be another 0–100 % quantity.

What it says about the 12 V battery (if right): it is topped up at about
59–66 %, an hour's top-up adds only 2–9 points, and three of the last four
came within two days of parking at 64–70 %. In October it fell from 79 % to
66 % in 6.3 days parked, about 2 points a day (a plugged-in OBD adapter adds
to that drain). All of this describes the battery fitted before the
2026-11 replacement (see the registration record below).

Second read, 2026-11-15 12:27 (charging, `captures/bmw_2026-11-15.txt`): the
header is new (clock +600,364 s = 6.95 days, km 77,753 = the odometer in the
SME's `DFA0` that minute, 12 V SoC **88.5 %**), the four records are
byte-identical and `409E` is unchanged. So the header does follow the car,
and there has been no top-up in the week since 11-08. What the header clock
marks is less clear than "last park": on both days it is 6–7 h behind the
SME's `DFE2` clock although the car had just been driven today.

**Dates are not shown in the app.** The records' clock stamps count seconds
on the car's own running clock. Turning one into a date needs that clock's
value *now*, and no DID is known that returns it (the SME's `DFE2` is a
wake-up stamp; the `409D` header is the last park, which is only "now" when
the car was parked minutes before the read, as in the table above). Until a
live clock read is found, the mileage stamp is the reliable reference, and
that is what the app shows (`LVBAT_TOPUP_KM`, in km or miles).

In the app (group `12v`, units `?`, every 5 minutes): `LVBAT_SOC_PARK`,
`LVBAT_TOPUP_SOC_START`, `LVBAT_TOPUP_SOC_END`, also listed (ungraded) in the
report metrics. Replay test:
`test/bmw_dme_12v_test.dart`.

### A live 12 V voltage from the EME? (2026-11-15, scale guessed)

The EME holds the DC/DC converter that feeds the 12 V system. Read while
charging (converter running):

| DID | i3 meaning | Reply | Reading |
|---|---|---|---|
| `DE88` | terminal 30B voltage | `1B E6` = 7142 | i3's `/ 100` gives 71 V. **`/ 500` gives 14.28 V** |
| `DE92` | DC/DC state: mode, LV voltage, load % | `01 1C 99 1A` | mode 1, 7321 → **14.64 V at `/ 500`**, load 26 % |
| `DDF6`, `DE89`, `DEBD` | DC/DC currents and voltages | `7F 22 31` | not on this car |

Two fields landing on a charging-system voltage with the same guessed scale
is promising, and it would be the live 12 V reading the DME sweep never
found. It is one read in one state. To confirm: read `DE88` and `DE92` again
with the car asleep after the charge (a resting battery is 12.4–12.9 V) and
in Ready next to J1979 `0142` (control-module voltage). The adapter's own
`ATRV` is no help: the Viecar reported 28.3 V at that moment (14.8 V earlier
the same day). Not in the signal set yet.

Second sample 12:41, accessory mode on (more 12 V load): `DE88` = 7206,
`DE92` = mode 1, 7470, load 49 %. The gap between the two grows with load
(0.36 → 0.53 V at `/ 500`), as a cable drop would. Against J1979 `0142` =
14.56 V and the DME's 14.30 V (below), `/ 500` puts `DE88` at 14.41 V and
`/ 512` puts `DE92` at 14.59 V: the scale is still not pinned down to better
than ~3 %. It needs a reading at a clearly different voltage (car asleep).

`DE75` is firmer: 9383 → 9517 between the two reads, `/ 32` = 293.2 →
297.4 V, while the SME's pack voltage `DD66` went ~293.5 → ~297.4 V. HV link
voltage, `u16 / 32` V.

### DME in accessory mode while charging (2026-11-15 12:39–12:47)

With accessory mode on, the engine ECU wakes: J1979 answers (`0142` module
voltage 14.1–14.6 V, `015B` 38.4 %) and so does the 4000–40FF block
(same 50 DIDs as on 11-08; all in `captures/bmw_2026-11-15.txt`).

| DID | Bytes (today; 11-08) | Reading |
|---|---|---|
| `409D`, `409E` | header as at 12:27, records unchanged | top-up history is static while awake |
| `409C` | `05 96 00 8F 00 46 00 04` (11-08: `05 96 00 8F 01 71 ..`) | **14.30 V** (`u16 / 100`), 14.3 V (`u16 / 10`), then a live value 68–94 (369 on 11-08, engine side running). Likely the battery sensor's voltage and a current or load figure |
| `40E6` | `00 8F 00 00 69 00 01` (`00 91 00 00 49 ..`) | 14.3–14.4 V, changes read to read; byte 4 climbed 103 → 105 in 7 minutes (73 on 11-08). Unknown |
| `40E7`, `40E8` | `00 92 01 00 4B 4A`, `90 01 4B 4A` (`00 92 02 00 4A 64`, `90 02 4A 64`) | 14.6–14.7 V and 14.4–14.5 V, a mode byte (1 today, 2 on 11-08), then 74–76 and 74–75 (74 and 100 on 11-08). These DO change now; on 11-08 they did not |
| `4023` | `47 80 5A 8B 15 01 .. 22 20 21 20 FF FF 5A 57 5E 54 ..` (`47 80 63 8D 03 00 .. 1E 1E 20 FF .. 63 63 4D FF ..`) | static over 5 reads. Byte 2 = 90 today, 99 on 11-08, next to the `409D` header's 88.5 % and 99.5 %: a stored 12 V state block. It holds one more entry than on 11-08 (4 vs 3 in both lists) |
| `400B` | `.. 00 90 ..` | bytes 6–7 = the same 14.3–14.4 V |

So the DME does expose a live 12 V voltage at the battery (`409C`, 10 mV
steps) and stored state, but no byte here can yet be named "12 V state of
health". The J1979 module voltage `0142` is already in the signal set and is
the only one of these the app shows. Next step for the unknown bytes: read
`409C`/`40E6`–`40E8`/`4023` in three states on one day (asleep-then-woken,
accessory, Ready) and watch which follow charge going in.

**The car has two 12 V batteries** (owner, 2026-11-15; a 2017 BMW bulletin
for the F30 330e also says to test "both 12 volt batteries"): one under the
bonnet, one in the boot. Nothing above says which battery a value belongs
to. Pointers, none of them proof:

- Two voltage levels keep appearing: ~14.3 V (`409C`, `40E6`, `400B`) and
  ~14.6 V (`40E7`, J1979 `0142`), with `40E8` in between.
- `40E7`/`40E8` carry two percent-like bytes side by side: 74 and 100 on
  11-08, 75 and 74 on 11-15.
- Each `409D` top-up record has two bytes not yet explained (13 and 18).
- A BMW battery sensor (IBS) reports one battery's voltage, current and
  temperature to the DME; the `409D` SoC figures are that battery's.

Owner, 2026-11-15: both were replaced recently. Boot: an H6 AGM, registered
as a **same-type replacement** (no capacity change) "within the last 150
miles"; it had a mains charger on it overnight around 11-11. Under the bonnet: a Motorcraft AGM (BAGM-H3), **not
registered** because the owner's tool cannot reach it. (BMW's catalogue for
the 2018 330e lists AGM parts of 70 / 80 / 90–92 Ah and one plain 40 Ah
battery, `61217635788`, without saying where each goes.)

Labels (owner's photos, 2026-11-15). Old boot battery: BMW/Varta VRLA/AGM,
`S: 61 21 6 806 748`, **12 V 70 Ah**, 720 A, sticker `17 B 341 D Z 0115`.
Read as year 17, day 341, that is 7 December 2017, a week before the pack's
hour counter started (`DF60`): almost certainly the factory battery, so no
earlier replacement and no earlier registration to look for. New boot
battery: H6 (48) AGM, 760 CCA, 950 CA, 120 RC, **70 Ah** per the retailer's
listing (the Ah line is not visible in the photo of the installed one).
Old and new are both 70 Ah AGM, so "same type" was the right registration.
No capacity figure has been read from the car; none of the decoded bytes is
a 70.

**`4022` looks like the registration record of the boot battery.**

| Bytes | 11-08 (77,698 km) | 11-15 (77,753 km) | Reading |
|---|---|---|---|
| 24–25 | `1E 59` | `1E 5F` | odometer / 10 now (7769, 7775) |
| 30–31 | `FF FF` | `1E 5A` | a stamp at 77,700 km, made after the 11-08 read |
| 36–37 | `1E 59` | `1E 59` | a stamp at 77,690 km: 63 km (39 mi) before today |
| 0–3, 10–13, 19 | `0000 0001`, `0000 0081`, `0E` | `0008 000D`, `0170 014E`, `4A` | counters that were near zero on 11-08 and have grown; two of them tick while the car is awake |
| 58–69 | `80 80 81 5A FF×8` | `7F 84 75 83 7B 83 7E 82 7F 80 81 5A` | a list that gained four byte pairs in the week |

So the battery was most likely registered at ~77,690 km, a few km before
the 11-08 capture, which fits "within the last 150 miles". If so:

- **All four `409D` top-up records (76,832–77,624 km) predate the
  registration.** They describe the old battery (or, for the October one,
  the days around the swap), not the new one. There has been no top-up since.
- The header's 99.5 % on 11-08 is probably the value the DME assumed at
  registration, not a measurement; a new battery is not delivered full.
  Today's 88.5 % is its running estimate a week on. A charger clipped to the
  battery's own negative post is not seen by the sensor on that clamp, so
  the overnight charge may not be in that figure.
- Not decoded: the counters and the pair list. Guess for the list, newest
  first: one byte per rest period, e.g. 12.7, 11.7, 12.3, 12.6, 12.7, 12.9
  if the first of each pair is volts × 10. Unconfirmed.

Open: what happened at 77,700 km (second registration? the charger?), and
whether the DME tracks the under-bonnet battery at all.

To settle it: see which battery has the sensor on its negative clamp (both?),
and compare a multimeter on each battery against `409C` (10 mV steps) with
the DC/DC off, when the two rest at different voltages.

Still untried: body controller (`40`) `DAD6`/`DAB3`/`4F0E` (terminal
voltages, IBS wake-up reason).

**Status: ~2,300 DME DIDs swept, no live 12 V battery data found.** Blind
sweeping the full 64k DID space at ~2 DIDs/s would take ~9 h. Better leads: the
DME's job file (EDIABAS SGBD / ISTA data) lists the real battery DIDs; or the
12 V data may sit in another ECU on a PHEV (`40` body/power management, or `3A`
EME, whose DC/DC feeds the 12 V system).

The hard part: even a found "SoH" byte can't be validated without a BMW battery
test / ISTA reading or a known-bad battery to compare against.

## Next

1. **Same-moment comparison with BimmerLink** to check the displayed-SoC
   formula and the cell-V values (one adapter, so read sequentially).
2. **SOH ground truth for `6335` = 83 %.** BimmerLink paid tier, or a
   coulomb-count capacity test (the Lyriq method) against the 330e's nominal
   capacity.
3. **Pack voltage:** no SME DID yet (`DD68` absent). Sweep `DD00–DDFF` /
   `DF00–DFFF` (`sme_probe.py --sweep DD00 DDFF`),
   looking for ~320 V. BimmerLink shows 320 V, so it exists somewhere (SME or EME).
4. Per-cell voltages (BimmerLink's "Cell Voltage >" drill-down suggests a
   per-cell DID exists).

## BimmerLink reference snapshot (ground truth for correlation)

Captured by Daniel, 2026-11-08 ~16:31, car parked, BimmerLink (free tier).

| Signal | BimmerLink value | Notes |
|---|---|---|
| Pack voltage | 320 V | |
| Pack current | −1.28 A | resting draw |
| Power | −0 kW | |
| SoC (displayed) | 93 % | |
| SoC lower / upper bound | 25 % / 78 % | SME usable window, in raw-SoC terms |
| Cell SoC min / avg / max | 73.79 / 75.95 / 77.10 % | raw per-cell SoC |
| Cell voltage min / avg / max | 3.979 / 3.997 / 4.003 V | Battery page shows avg 3.996 V |
| Cell voltage deviation | 24 mV | max − min |
| Defective cells | none, modules 1–11 all OK | |
| E-motor temp 1 / 2 | 103.5 / 107.0 °F (39.7 / 41.7 °C) | |
| Motor RPM / torque | 0 / 0 Nm | parked |
| Mileage | 48,281 mi | |
| Ambient | 59.9 °F (15.5 °C) | |
| HV error memory | EME (3A): none; SME: none | |
| Locked (paid tier) | SoH, SoH trend, cell temperature, battery info, range | |

Derived (hypotheses, check against our own reads):
- **~80 cells in series:** 320 V ÷ 3.996 V ≈ 80.1.
- **Displayed SoC vs raw window.** If displayed = (raw − 25) ÷ (78 − 25), then the
  min cell (73.79 %) gives 92.1 % and the average (75.95 %) gives 96.1 %. The
  displayed 93 % is closer to the min-cell mapping. Unconfirmed.
- **J1979 `015B` looks like raw SoC, not displayed.** On 2026-11-08 `015B` read
  71.4–71.8 % while the SME's displayed SOC was 90.7 % and min cell SoC 71.44 %;
  a later read gave `015B` 71.0 % vs min cell SoC 70.86 %. Three samples fit
  `015B` ≈ min cell SoC (within its 0.4 % resolution).
- **Displayed SoC ≈ (avg cell SoC − window min) ÷ (window max − window min),
  but ~0.7 points high** (91.4 vs 90.7, 90.3 vs 89.6). Close, not exact.
- 24 mV spread at ~4.0 V and rest is healthy; no defective cells flagged.

Note: our SME reads were ~1 h later with the car running (displayed SoC 90.7 %
vs 93 % here), so values differ slightly as expected.
