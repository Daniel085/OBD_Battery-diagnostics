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
| `DF60` | u32 10594, 78034 | ? (78034 is near, but above, the 77,698 km odometer) |
| `DD8E`, `DD90`, `DD91`, `DF66`, `DF76` | count arrays | histograms (temperature/SoC/current bins?) |

Validate with a before/after read around ONE event:
`python3 sme_probe.py --read DFAC DF67 DF62 DF60 DD8E DF76 DFAA DFAD DFE2 DDC9`.
After one plug-in charge, a session counter rises by exactly 1 and a charge
total rises by the energy added (a 3 kWh top-up ≈ 9.5 Ah at 317 V: +9,500 if
mAh, +3,000 if Wh). After one drive, a drive counter rises and charge counters
don't.

## Per-module SoH? Clock and event log (unvalidated)

- `DFAA` = 85, 85, 85, 84, 83, then FF×6 (5 modules of 11 slots). Pack SOH
  `6335` = 83 = the **minimum module**, the usual "weakest module" rule.
  Hypothesis: per-module SoH. Check: it must stay constant while SoC changes.
- `DFAD` = 71, 71, 71, 71, 70 at min cell SoC 70.2 % → per-module SoC.
- `DFE2` bytes 1–4 = u32 280,857,216: an SME **seconds clock**, zero ≈
  mid-Dec 2017 (production / first power-up?). Read during the DF sweep.
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
