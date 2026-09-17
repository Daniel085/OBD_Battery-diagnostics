# Cadillac Lyriq (2025) — reverse-engineering log

Live capture against a real 2025 Cadillac Lyriq (VIN `1GYKPTRL5SZ302606`),
via a Raspberry Pi BLE bridge → Viecar ELM327 v2.2 clone → OBD-II port.
This records what has been **confirmed on the vehicle**, so the RE can resume
without repeating discovery.

## Confirmed transport

| Item | Value |
| --- | --- |
| OBD protocol | **ISO 15765-4, CAN 29-bit / 500 kbps** — force with `ATSP7` |
| Auto-detect (`ATSP0`) | **Fails** — hangs on `SEARCHING...` then `STOPPED`. Must force SP7. |
| Adapter | Viecar BT4.0 (ELM327 v2.2 clone). GATT: service `fff0`, write `fff2` (handle `0x0016`), notify `fff1` (value handle `0x0014`). Write with *write-without-response*; notifications flow without an explicit CCCD write. |
| 12V (`ATRV`) | ~14.3 V with car in Ready |

## ECUs on the propulsion bus

Functional broadcast `18DB33F1` / `0100` returned six responders. GM 29-bit
addressing: request `18DA<ecu>F1`, response `18DAF1<ecu>`.

| ECU (source) | Notes |
| --- | --- |
| `45` | Holds VIN + `F1A0` only; rejects most DIDs (`7F 22 31`). Gateway-like. |
| `1D` | Holds VIN, `F18C` = `FFFFFF…`. Rejects battery DIDs. |
| `17` | Holds VIN, `F18C` = `FFFFFF…`. Rejects battery DIDs. |
| **`40`** | **Battery / propulsion controller (BECM).** Holds VIN, a real `F18C` serial (`…30303234313400`), and answers a large block of `43xx` DIDs with live data. **This is the HV-battery module.** |
| `28` | Holds VIN. Rejects battery DIDs. |
| `CB` | Answered the `0100` broadcast but returns `NO DATA` to physical `18DACBF1`. Different request address, TBD. |

Identify a module by reading `22F190` (VIN), `22F18C` (ECU serial),
`22F1A0` — see `~/.claude-obd-pi/captures/ecu_id_result.txt`.

## ECU 40 (BECM) — DIDs seen answering with data

Addressing: `ATSH 18DA40F1`, `ATCRA 18DAF140`, `ATFCSH 18DA40F1`, then `22<DID>`.

- **`4301`–`4307`** answered with single-byte payloads; values are state-dependent
  (e.g. `4304`=0x12, `4306`=0x10 in one read; mostly `00` when idle). Look like
  **status/flag registers**, not analog signals.
- Many `434x`/`436x`/`41Ax` DIDs answer with small 1-byte values (flags/counts):
  e.g. `436F`=0x0050, `435D`=1, `438B`/`438C`=1, `41A5..41A8`=2.
- Beyond `4307` and outside these clusters, ECU 40 returns `7F 22 31`
  (requestOutOfRange).

## Generic J1979 mode-01 PIDs

Read via functional broadcast `18DB33F1` then per-ECU. Supported-PID bitmasks
(`0100/0120/0140/0160/0180/01A0`) show which ECU claims what:

| ECU | # PIDs | Notable |
| --- | --- | --- |
| **28** | **53** | Full engine-style set incl. `05` coolant, `0F` intake, `46` ambient, `0C` RPM, `0D` speed, `04` load, `2F` fuel level, `33` baro… |
| 17 | 14 | speed, run time, distances, `42` voltage |
| 40 / 45 / 1D / CB | 4 | `01`, `20`, `40`, `42` (module voltage) only |

**Coolant caveat — declared but empty.** ECU 28 lists `0105` (coolant), `010F`,
`0146`, `015C` as *supported*, but querying them returns **`NO DATA`**. They are
legacy-engine compliance placeholders with no live sensor on this EV. Only
`010C` (RPM → `0000`) and `0142` (module voltage, real: ~13.7 V across ECUs)
return anything. **Real thermal data is NOT in the generic PIDs — it's in the
proprietary ECU-40 DIDs** (the `4124`/`4127` temp-array candidates below).

## CONFIRMED signals (validated by charge/idle correlation)

Positively identified by watching them respond to a 3.45 kW charge start/stop:

| Signal | DIDs (ECU 40) | Formula | Confirmation |
| --- | --- | --- | --- |
| **Module/section voltage** ×3 | `416C`, `416D`, `416E` | `u16 / 100` V | 51.14 V charging → 50.98 V idle — moved the correct direction when charge stopped |
| **Temperature sensors** | `40E5` (~25°C), `40E6`+`4139`+`413A` (~23°C), `4124`+`4125` (~31°C), `4127`+`412A`+`412B` (~33°C), `4147` (~24°C) | `u16 / 32` °C | Tight 23–33°C spread; ticked up under charge (e.g. 40E6 738→741) |

These are real, repeatably-read values with physical behaviour — safe to wire
into the signal set. (The ÷32 temp scale is a working fit across all sensors; a
second reference temperature would pin it exactly.)

Still UNCONFIRMED: **SOC** (`406E`=47, best guess, didn't move over minutes) and
**pack current** (never located — did not appear in the sampled DIDs even with a
clear 3.45 kW / ~10 A charge running; it's in an unswept DID).

## Candidate analog signals (captured under charge — best guesses, UNCONFIRMED)

Full capture in `~/.claude-obd-pi/captures/capture_all.txt`. Conditions: SOC 49%,
AC charging 1.4 kW / 6 A @ 240 V, pack nominal ~355 V. ECU 40 sleeps fast when
idle, so all of this requires the car in Ready.

| DID | raw (hex) | decoded | Hypothesis (needs confirmation) |
| --- | --- | --- | --- |
| `416C` | `13F4` | 5108 → **51.08 V** (÷100) | Module/section voltage |
| `416D` | `13EF` | 5103 → **51.03 V** | Module/section voltage (3 tightly-matched — healthy) |
| `416E` | `13F4` | 5108 → **51.08 V** | Module/section voltage |
| `415B` | `001EFD17` | 2,030,871 | Cumulative energy counter (Wh?) — SOH-relevant |
| `415C` | `001B34D2` | 1,782,994 | Cumulative energy counter (Wh?) |
| `406E` | `…2F` | 47 | **SOC candidate** — the one value that moved (46→47); near 49% |
| `4127`/`412A`/`412B` | `0418` | 1048 (×3 identical) | Temperature sensor array (3 sensors) |
| `4124`/`4125` | `03DC` | 988 (pair) | Temperature pair |
| `40E5`/`40E6` | `0325`/`02D9` | 805 / 729 | Analog pair (drifted 800→805, 727→729 under charge) |
| `4149` | `0184` | 388 | Possibly pack voltage (scaling TBD) |
| `4102`/`4106`/`4107`/`410A` | `121202` | [18,18,2] | Repeated cell/module status |
| `418D`–`4191`, `4148`, `414E`, `4158` | multi-frame | arrays of `18DAF140 2N ..` frames | **Per-cell / per-module data blocks** (mostly zero this capture) |

Not yet found: **pack current** (should have flipped negative under charge but
didn't appear in sampled DIDs) and a confirmed **SOC**. `40E5`/`40E6` drifting
slightly under charge makes them live-analog candidates worth correlating.

### How to confirm (next stable session)
- Drive **SOC up several %** (charge longer / faster) and re-capture: whichever
  DID tracks it is SOC. `406E` and `40E5/E6` are the prime suspects.
- Confirm the `416C/D/E` module-voltage guess: they should **rise under charge,
  fall under load**.
- The `418D`–`4191` multi-frame blocks are the likely **per-cell voltage arrays**
  — read them with long settle when the pack is active/balancing.

## Blocker & how to resume

The Pi Zero's BLE + the Viecar clone is only reliable for **~60–90 s bursts** at
the range tested, then connects/reads start timing out. Long systematic sweeps
are impractical on this link. To finish:

1. **Stabilise the link** — Pi physically next to the OBD port, or a better
   adapter (OBDLink CX), or a wired CAN HAT on the Pi.
2. **Correlation sweep** — with SOC known (49% now), sweep ECU 40's 2-byte DIDs
   and flag any reading ~49 (raw `0x31`), ~490 (×0.1), or ~4900 (×0.01). Repeat
   at a different SOC to confirm it tracks.
3. **Temps** — look for values in a plausible °C range (raw ~10–60, or offset
   like `raw − 40`).
4. Promote confirmed DIDs into `signalsets/Cadillac-Lyriq-2025/` and contribute
   upstream to OBDb.

## Repro (Pi bridge)

`~/.claude-obd-pi/` holds the driver scripts (gatttool + pexpect). Working path:
`gatttool -b 00:1D:A5:00:00:01 -t public -I` → `connect` (retry; needs
`-t public`) → `char-write-cmd 0x0016 <hex>` → read `Notification handle=0x0014`.

---

## Session 2026-08-14 — capacity/SOH register hunt (stable link)

Link was stable all night (multi-minute sweeps, no dropouts). Car in **Ready**,
parked, not charging. Full raw captures: `captures/2026-08-14-capacity-hunt/`.

### New confirmed/near-confirmed (ECU 40, `18DA40F1`)

| DID | Value tonight | Read | Status |
|---|---|---|---|
| `44C0` | `3E 3F 3F 3F` = 62,63,63,63 | 4 bytes | **SOC% (displayed), prime candidate** — rock-stable parked; matches cell-V-implied SOC (~3.72 V/cell). Confirm vs dash. |
| `44C1` | `37 39 37 39` = 55,57,55,57 | min/max pairs | SOC min/max (cell-balance spread) candidate |
| `443C` | `0x64` = 100 | 1 byte | **SOH% candidate** |
| `4441` | `0x64` = 100 | 1 byte | **SOH% candidate** |
| `451D` | `0x63` = 99 | 1 byte | **SOH% candidate** (99 on a 1-yr-old pack is plausible) |
| `4510` | `0x5A` = 90 | 1 byte | **Charge-target % candidate** — confirm vs user's charge-limit setting |
| `44C5` | `01 60 03 62 00 60 03 62` | static record | **Capacity record candidate**: u16 pairs (352, 866)+(96, 866) → 866 = **86.6 kWh?** Byte-identical across reads. |
| `434F` | `0x46` = 70 → **30 °C** | byte − 40 | HV batt temp CONFIRMED (matches `4127` = 32.75 °C); OBDb `22434F` mapping verified |
| `448F` | `0x001EFE52` = 2,031,186 | u32 | **≡ `415B` exactly** (same register, two DIDs). Frozen while parked-in-Ready → odometer or lifetime-energy counter, NOT runtime. OBDb maps `448F`=odometer (on ECU 1A). Confirm scale vs dash odometer. |
| `406E` | 35 → 44 in 10 min, parked | byte | **NOT SOC** (jumped while parked). Likely aux/DCDC load. Demoted. |

### Conditional charging DIDs — the pack-current story

`4368`/`4369`/`436A`/`4373` now return **NRC 0x31 requestOutOfRange** when not
charging (previously read 0 during a charge session). They are **conditional
registers that only exist while charging** — this is why pack current was never
found. **Next charge session: read `4368–436C` + `4373` while actually charging.**

### ECU 1D pack voltage (`2233E5`) — first capture

Answers: `0x85` = 133 (stable). Module voltages imply pack ≈ 357 V → scale is
NOT ×0.1/×1/×2. Need a second operating point (charging, pack ~380+ V) to derive
the formula. OBDb documents this DID as pack voltage.

### Ranges closed tonight

- `4200–42FF`, `4400–44FF`, `4500–45FF` swept (hits logged in captures).
- `8000–80FF`: **completely empty**.
- Per-cell blocks `4181–4240` (OBDb 96-cell arrays): `418E` returns a correctly
  sized 173-byte multiframe of **all zeros** even in Ready → not populated
  without (likely) security access. Same class of block as CB SOC: exists,
  gated. `41C0` = `01 02 01 02` (non-zero, meaning unknown).
- ECU CB SOC (`2B43`/`27C6`): re-confirmed gateway-blocked (NO DATA).

### To confirm next session (needs user/dash input)

1. **Dash SOC %** → confirms `44C0`. 2. **Odometer** → nails `448F` scale.
3. **Charge-limit setting** → confirms `4510`=90. 4. **While charging**: read
`4368–436C`/`4373` (current!), `33E5` second point, watch `44C0` climb.

---

## Session 2026-08-14 (evening) — live charge experiments @ 9 kW

Charge/stop/unplug sequence with captures at each state. Raw files:
`captures/2026-08-14-capacity-hunt/` (+ Pi `~/obdbridge/chglog.txt` overnight log).

### Confirmed by state transitions

| DID | Behavior observed | Conclusion |
|---|---|---|
| `441F` | All-zero idle → populated at charge start (`3E 22 03 5F 0E 00 1A 1A 00 02`) → **persists through charge-stop AND unplug** | **Charge-session record** (durable). Fields: `0x3E`=62 gross SOC at start; `0x035F`=863 (matches 44C5 record, capacity/energy?); `1A 1A` = 26,26 → **26 A DC ≈ 9 kW / ~350 V — best pack-current candidate**; `02` = state. Overnight taper will confirm the amps bytes. |
| `4149` | 384 idle-plugged → 388 charging → held 388 while stopped-plugged → **100 immediately on unplug** | **EVSE pilot advertised current ×0.1 A** (38.8 A ≈ 9.3 kW @ 240 V ✓; 10.0 A default unplugged). NOT cell voltage as first guessed. `441E`'s repeated `0x0180`=384 entries likely the related AC-limit table. |
| `4575` | Jitters 7–12 in all states incl. stopped | Demoted — not charge power. |
| `33E5` | Answers on ECUs 17/1D/28 = 131/133/139 | **12 V rail voltage ×0.1 V per-ECU** (13.1/13.3/13.9 V under DCDC float). OBDb "pack voltage" attribution is wrong. Demoted. |
| `4368–436A`/`4373` | NRC 0x31 even while AC-charging at 9 kW | NOT AC-charge-conditional. Likely DC-fast-charge-only (test at a DCFC). `436B/C`=0 throughout. |
| 11-bit (`7E0–7E7`) | ALL NO DATA incl. 7E4/7E7 | Gateway forwards 29-bit only. OBDb's 7E7 96-cell ECU must be a hidden 29-bit addr (roster scan needed; 53 was found this way). |
| `415B`≡`448F` | Frozen during charging too | Not an energy counter. Odometer: raw/64 = km (2,031,186/64 = 31,737 km = 19,720 mi = dash ✓ **CONFIRMED**). |

### SOC referee status (dash: 56% pre-charge → ~62 during charge → 60 settled post-stop)

- `44C0` (62,62,63,63): matched dash *during* charge; slow event-driven refresh.
  Gross-vs-displayed buffer story still open.
- `44C1` (55,57→55,54): matched pre-charge dash 56 but moved DOWN while charging —
  probably NOT displayed SOC (or min/max of something else).
- ECU 40's registers refresh slowly/on-events — it is an energy/summary module;
  the live BMS is CB (gateway-blocked). Overnight 56→100% log will calibrate.

### Overnight logger

`~/obdbridge/chglog.py` (nohup) — samples 19 DIDs every ~2.5 min for 9 h
(started 18:20ish, ends ~03:20) → `~/obdbridge/chglog.txt`. Car charging to
100%. NEXT SESSION: pull log, plot 44C0/44C1/441F/4149/416C/4127 vs time;
calibrate SOC registers against 100% endpoint; confirm 441F amps bytes via taper.

---

## Session 2026-08-15 (overnight) — PACK CURRENT FOUND via Bolt PID research

User asked how others measure Ultium capacity → researched community sources.
**Answer: the Chevy Bolt PID family partially carries over to Ultium.** Bolt
community reads capacity as `22 41A3` (u16÷10 Ah) on BECM header `7E4`, SOC as
`8334` (÷255×100) / `43AF` (÷65535×100), HV current as `22 2414` on **`7E1` (the
powertrain module, NOT the BECM)**. Our confirmed `434F` HV-temp is itself a
Bolt DID — the crossover is real.

### Tested on-car (charging 9.22 kW AC, "charging-only" wake mode)

- **ECU 17 `2414` = PACK CURRENT — CONFIRMED.** s16, ÷20 → amps, negative =
  charging. Read −443…−461 raw = −22.2…−23.1 A with live jitter. (ECU 17 =
  Lyriq analog of Bolt 7E1.) The 2-night hunt is over: current was never on
  ECU 40.
- **ECU 17 `2429` = PACK VOLTAGE — u16 ÷64 V** (0x5806=22534 → 352.1 V).
  Copies at `2428`/`242D`/`2434`/`2489` (multiple measurement points, all equal
  with contactors closed). GM ÷64 fixed-point, same as odometer.
- `24AA` u16, live (~25755-25800; ÷64 ≈ 403 — charge-target voltage?). TBD.
- Bolt BECM DIDs `8334`/`43AF`/`41A3`/`4531`/`43A5` → ALL NRC 0x31 on ECU 40
  **in sparse charging-only mode**. RETRY WITH VEHICLE ON — top priority; 41A3
  is the controller-reported capacity we've been hunting.
- **Charging-only wake mode discovered:** unattended AC charging leaves ECU 40
  sparse (441F session record stays empty, 416C/D/E read 0, 4149 stale) while
  44C0/44C1/40E5 stay live. Vehicle-ON charging (evening session) populates
  everything. Register availability is MODE-DEPENDENT.

### Logger v2 (`chglog2.py`, 45 s cadence, 5 h)

Adds ECU 17 `2414`/`2429`/`24AA` per cycle → tonight's 60→70% charge is a
**coulomb-counting session**: ∫I·dt across the SOC swing → capacity estimate to
cross-check `41A3` when we get it. Sample: I=−23.05 A, V=352.1 V (8.1 kW DC from
9.22 kW AC ≈ 88% OBC efficiency).

### Ops notes

- `pkill -f chglog.py` inside an ssh one-liner kills the ssh session itself
  (pattern matches the remote shell's own cmdline) → exit 255. Use `chglo[g]`.
- Pi timestamps in chglog.txt are UTC.

### Charge-session analysis (ended 09:52 UTC; log `captures/2026-08-14-capacity-hunt/chglog.txt`)

37 samples 09:14–09:53 UTC. Steady **−22.75 ±0.3 A** at 352.1 V (≈8.0 kW DC from
9.22 kW AC ≈ 87% wall-to-pack), current cut cleanly to 0 at the 70% target
between 09:51:26 and 09:52:29. Logger-window coulomb count: −14.5 Ah / −5.1 kWh
DC; extrapolated to full session (flow ≈ 08:45→09:52, ~67 min): **≈25 Ah,
≈9.0 kWh DC** for a dash swing of ~59/60→70%. → rough usable capacity
**~83–91 kWh** (uncertainty dominated by exact flow-start time and stale start-
SOC). Consistent with a healthy Lyriq usable pack; 41A3 (BECM-reported) remains
the precise target.

Register behavior notes: `2429` pack-V froze at 0x5806 all session (slow-refresh
in sparse mode — real V must rise with SOC); `44C0` stayed [59,58,59,59]
throughout (does NOT track in charging-only mode — it updates on vehicle-on
wakes); `24AA` climbed smoothly 403→421 even after current stopped → it's a
**~0.5 Hz uptime/tick counter, NOT a voltage** — demoted; `40E5` pack temp
rose only 23.28→23.59 °C (gentle charge, cooling working).

### Session 2 (70→80%, ended ~11:23 UTC 2026-08-15) — CAPACITY MEASURED

66 samples, steady −22.3 A mean. Integrated −26.1 Ah logged + ~2.4 Ah missed
start + ~0.7 Ah missed tail = **29.2 ± 0.8 Ah for exactly 10.0% (cutoff-to-
cutoff)** → **292 ± 8 Ah ≈ 103 ± 3 kWh @ 352 V nominal ≈ 100% of the 102 kWh
rating. Measured SOH ≈ 100%**, agreeing with SOH registers 443C/4441=100,
451D=99. Mid-charge dash %s (user: 76% at 11:11) are nonlinear vs coulombs —
trust only cutoff endpoints. BlueZ note: "Function not implemented" on connect
= restart bluetooth service (systemctl), not just hciconfig.

### Ready-mode burst (2026-08-15, car ON, post-80%-charge, cable in)

- **`41A3`/`8334`/`43AF`/`4531`/`43A5`: NRC 0x31 even in Ready — DEFINITIVE
  NEGATIVE.** The Lyriq BECM does not implement the Bolt capacity/SOC DIDs in
  any mode. Bolt crossover is partial (434F temp, 2414/current family) but the
  capacity register moved or is CB/gateway-side on Ultium. GM-reported capacity
  via OBD port: CLOSED. Coulomb-count method is our capacity source.
- **`44C0` DEMOTED — NOT SOC.** Reads 59-61 with dash at 80% after the charge
  (earlier match at ~62 was coincidence). No SOC register exists on ECU 40 at
  all; SOC is CB-only (gateway-blocked). `44C1` (45-48) also unexplained.
- **`2429` (and 2428/242D/2434/2489) DEMOTED to PACK NOMINAL VOLTAGE constant**
  (0x5806 = 352.1 V ÷64): identical at 70% charging and 80% Ready — a live pack
  V would read ~385 at 80%. Capacity math unaffected (Ah × nominal V = rated
  kWh convention). Live pack voltage NOT yet found via port (CB territory).
  Wall-to-pack efficiency estimate improves to ~91-93% (real V ~375-385).
- **`2414` sign convention CONFIRMED: +0.9 A in Ready** (positive = discharge,
  small aux draw) vs −22.75 A charging. Current register fully characterized.
- `441F` stays zero in Ready-not-charging (populates only while vehicle-on
  charging). `4149` = 384 (38.4 A pilot — cable still in ✓). `44C5` changed
  again (00 56 01 59 02 57 02 58 → u16s 86,345,599,600) — NOT static config;
  multi-field state record, needs more samples to decode. `4368-436C`/`4373`
  NRC even in Ready+plugged → DCFC-only stands.

## 2026-09-12 session — 17→50% charge, gross-vs-usable SOC cracked

Capture: `captures/chglog_2026-09-12.txt` (logger3, ~45 s cadence, ECU17 I/V +
ECU40 records incl. SOH regs). Charge start caught within one sample of bus
wake (11:35). Dash: 17% at plug-in → 50% cutoff.

**Capacity measurement (best yet):** coulomb count = **98.1 ± 2.3 Ah**
(34.5 kWh DC @ 352.1 V nominal), steady −23 to −25 A across ~4 h wall time
(five link bursts, gaps interpolated). Dash 17→50 = 33% → full pack
**≈ 297 Ah ≈ 104.7 kWh ≈ 102.6% of the 102 kWh gross rating → SOH ~100%.**
Consistent with the Aug 70→80% result (292±8 Ah); larger swing tightened it.

**GROSS vs USABLE SOC — CONFIRMED (answers the "gross capacity = SOH"
question).** The `441F` charge record's first two data bytes carry TWO SOC
scales simultaneously:
- byte0 `3B`→`3A` = **59→58 = GROSS/internal SOC** (BMS full-window %).
- byte1 `18`→`17` = **24→23 = USABLE SOC** offset — tracks the dash (dash
  17→... ; byte1 sits a few points above dash, consistent with a usable scale).
- So at dash 17% the pack was ~59% gross. This is why "Ah per dash-%"
  extrapolates to the GROSS rating (102 kWh), not usable (~85 kWh): the dash
  spans the usable window, the coulombs span the same physical charge, and the
  ratio lands on gross. **The dash-to-gross mapping is now a measured data
  point, not a guess.**

**`44C5` decoded as a record, first field = gross SOC ×… :** payload
`00 53 / 00 54 / 01 55 / 02 54 / 00 00` at start → `03 54 / 00 54 / 01 54 /
01 54 / 00 00` mid/end. First u16 field moved `0x0053`(83)→`0x0354`(852)
during charge = **tracks gross SOC-ish, NOT a static capacity value** →
DEMOTED as a capacity register. The `0x0154`≈340 fields look like a repeated
config/limit constant, not capacity.

**SOH registers `443C`/`4441`/`451D` = 0x00 all session** — did NOT populate
even with the car awake and actively charging (contrast Aug: 100/100/99 seen
in some wakes). Confirms these are **event-computed / cached**, not live —
they refresh on some BMS trigger, not on demand.

**OPEN HYPOTHESIS (2026-09-14) — SOH regs latch on a HIGH/FULL charge, and a
deep discharge clears them.** Fits all data: Aug read 100/100/99 at 56-70%
(car had been fully charged recently → latched value held across partial
sessions); Sep 12 read 0x00 the whole 17→50% run (deepest discharge we'd
seen, to 17% — cleared the latch, and stopping at 50% never re-charged high
enough to re-latch). Strict "only reports at exactly 100%" is already
falsified by Aug (populated at 56-70%), so the working model is:
*value recomputes/latches at the end of a sufficiently high charge and holds
until a deep discharge resets it.*
**FALSIFYING TEST (next session): charge 50→100%, sample 443C/4441/451D
CONTINUOUSLY, record the exact SOC at which they flip 0x00 → value.**
  - populate mid-climb (80-90%) → "recompute after high charge", not 100%.
  - stay 0 until complete, then show → strict full-charge latch.
  - stay 0 even after 100% → deep-discharge reset needs a full recal cycle
    (charge-after-deep-discharge); may take another full cycle to restore.

## 2026-09-14 session, leg 1 — 38→73% with a WALL METER

Capture: `captures/chgloghi_2026-09-14.txt` (30 s cadence). Car in
**unattended/sparse mode** the whole leg (441F all-zero, 416C=0, 4149 stale
16 A) — the car was never "on". Dash 38% → stopped at 73%. User's wall-side
power meter: **38.29 kWh AC delivered** (first time we have the AC side).

**Coulomb count: 104.9 ± 1.0 Ah** over 4.56 h, steady −24.0 → −22.1 A (mild
taper starting). 35 dash points → **3.00 Ah/pt → ~300 Ah ≈ 105.6 kWh @ 352.1 V
nominal ≈ 103.5% of 102 kWh.** Mid-charge check: at 79.1 Ah the dash read
65% exactly as predicted from 2.9 Ah/pt (third session on the same slope).

**WALL-METER RECONCILIATION → current-scale/voltage bound.** 104.9 Ah ×
352.1 V = 36.95 kWh DC vs 38.29 kWh AC = **96.5% "efficiency" at nominal V**
— too high for an onboard AC charger (typ. 88-93%). Since DC ≤ ~0.93 × AC =
35.6 kWh, either (a) the true AVERAGE pack voltage over 38-73% is ≲ 340 V
(below the 352 nominal constant), or (b) `2414` reads ~3-5% HIGH (true
≈ 99-101 Ah), or a mix. This also explains why every session lands at
102-104% of "102 kWh gross": a consistent few-% over-read. **Treat SOH as
≈100% (±3%), not 103%.** Live pack V (CB, gateway-blocked) or a second
current reference would settle it; DoIP/ENET is the path.

**`4127` DEMOTED — CONSTANT, NOT A SENSOR.** Read exactly 0x0418 (32.75 °C /
91.0 °F) on every sample of this session, Sep 12, and Aug. A thermal
setpoint/limit, not a temperature. `40E5` is the live pack/coolant temp
(72.5 → 75.0 °F, +2.5 °F over 4.5 h at 8.4 kW AC — thermal management barely
working). TODO: relabel 4127 in the signal set, drop from temp aggregation;
re-examine 4124/40E6 for the same pattern.

**SOH regs `443C`/`4441`/`451D`: 0x00 throughout a 38→73% charge** (sparse
mode). Latch test INCOMPLETE — did not reach 100%. Next: continue to 100%,
then put the car in READY and read the regs in vehicle-on mode (sparse mode
may hide a latched value).

## 2026-09-14 leg 2 — SOH REGS RESOLVED (it's vehicle-on, NOT charge-to-100%)

At **73% SOC**, user switched the vehicle ON (Ready). At that instant
(15:12), in lockstep, `416C` module V woke (0→51.08 V), EVSE pilot corrected
(16→38.8 A), and the SOH regs began populating. **This kills the "latch at
100%" hypothesis: the gate is VEHICLE-ON vs sparse/unattended-charging mode**,
the same mode split that governs 416C/441F/4149. Every prior 0x00 reading was
because the car was in sparse mode; every populated reading (Aug) was
vehicle-on. SOC was irrelevant.

**Settled values (12 min steady, car on, ~3 A trickle at 73%):**
- **`451D` = 0x5D = 93** — rock-steady from first read, the reliable one.
- **`443C` / `4441` = 100 / 100**, but INTERMITTENT: mostly 0x00, flicking to
  0x64=100 only ~1 sample in 6 (15:16, 15:13). These two are refresh-gated /
  slow-cadence even vehicle-on; do not treat their 0x00 as "zero SOH".
- Earlier transient 63/83 (15:13) was the mid-recompute ramp, not a real SOH.

**Interpretation:** `451D`=93 is the trustworthy controller SOH-ish figure;
`443C`/`4441`=100 look like a capacity/verified flag pair. **451D=93 vs Aug's
99** is a real delta worth watching, BUT our coulomb count says ~100% (±3%,
after the wall-meter over-read correction) — so 451D is either a different
metric (e.g. a conservative/among-cells min) or the pack genuinely reads mid-
90s to the BMS while integrating to ~100%. Both plausible; not resolved.
**Coulomb count remains the primary SOH source; 451D is a cross-check to log,
not a verdict.** Capture updated: `captures/chgloghi_2026-09-14.txt`.

**App implication:** SOH regs are only meaningful vehicle-on; surface them
only when 416C≠0 (vehicle-on detector we already have), label as
"controller-reported (BMS)" distinct from our measured SOH, and prefer 451D.

## 2026-09-17 — full-cycle charge to 100% (75→100%)

Capture: `captures/chg100_2026-09-17.txt`. Fixed flock-supervised logger
(tools/pi-logger) — ran clean start to finish, no data loss (the whole point
of the 09-15 fix). Charge 11:57→15:29, dash 75%→100% (true end: user waited
for wall current to stop, not the dash's premature "complete").

**FULL-CYCLE CAPACITY (best anchor yet — true 100% cutoff): 73.9 ± 2.0 Ah =
26.03 kWh DC @ 352.1 V nominal. 2.96 Ah/dash-pt → ~296 Ah → ~104 kWh →
~102% of 102 kWh gross.** Fourth session agreeing (Aug ~2.9, 09-12 3.00,
09-14 2.87, 09-17 2.96 Ah/pt). ±2.0 Ah wider than 09-14 because of one 469 s
link gap during the run (interpolated). SOH ~100%, firmly.

**CHARGER EFFICIENCY — now pinned with a full-cycle wall reading. 31.07 kWh
AC → 26.03 kWh DC(nominal) = 83.8%.** This is BELIEVABLE for onboard AC
charging (unlike the earlier 96.5% partial artifact), so it RESOLVES the
09-14 puzzle in favour of: **the 2414 current scale is about right, and the
"102-104% of gross" we keep computing is because avg pack V during charge is
somewhat ABOVE 352 nominal** — at ~375 V avg the eff is ~89%, a very typical
number. Net: pack is genuinely ~100% SOH; report it as such.

**SOH regs at true 100%, vehicle-on: STILL UNSTABLE / did not settle.** As
the car went to Ready (~15:26-15:30) the regs churned — 443C/4441/451D seen
as (100,100,0) → (0,33,33) → (33,33,33) → (0,0,0) across ~4 min, then the car
slept. NEVER held a steady value this session (contrast 09-14 where 451D held
93 for 12 min). So we did NOT get the clean "does 451D climb from 93 toward
99 at 100%" read — the car wasn't kept in Ready long enough for the recompute
to converge. **Still open. Next: at any SOC, keep the car in Ready (driving)
5+ min undisturbed and log until 451D holds steady 3+ samples.** Confirms
again: charge-to-100% does NOT populate them (sparse mode all through
charging); vehicle-on does, but convergence takes minutes.

### RESOLVED same day (15:35, car kept in Ready ~5 min at true 100%)

**`451D` = 93, ROCK-STEADY (4 consecutive samples, vehicle-on).** Identical
to the 73% reading on 09-14. **So 451D does NOT track state of charge — it is
a stable, SOC-independent battery metric.** 93 at 73% and 93 at 100% = it is
reporting a fixed pack property, i.e. a state-of-health / capacity-health
figure, not "how full is it right now". (443C/4441 stayed 0 here — their
intermittent refresh didn't fire in this window; 451D is the reliable one.)

**Interpretation of 451D=93 vs our coulomb count ~100%:** these are different
quantities and both are probably "right":
- Coulomb count (~100% of 102 kWh gross) = usable throughput vs the rated
  GROSS pack — a healthy 2-yr-old Ultium measures ~full gross.
- 451D=93 = likely GM's SOH against a spec that already discounts gross→
  beginning-of-life-usable, OR a deliberately conservative/among-cells figure.
  93% SOH on a low-mileage Lyriq is plausible as a manufacturer metric.
Either way: **for the app, report BOTH** — our measured capacity (headline,
physical, method-transparent) AND the controller's 451D as "BMS-reported SOH"
when vehicle-on and settled. Do not average them; they answer different
questions. **451D confirmed SOC-independent → safe to surface as a stable
SOH-ish readout.** Prior "does it climb 93→99 at 100%" hypothesis: ANSWERED —
it does NOT climb, stays 93.

## 2026-09-17 16:22 — dedicated VEHICLE-ON sweep (`captures/vehon_2026-09-17.txt`)

Car in Ready, full charge, 6 rounds over ~65 s + targeted sweeps. Four
questions, three answered definitively.

**NEW SIGNAL: `451E` = 0x29 = 41, rock-steady** (all 6 rounds), sitting right
beside `451D`=93. Same vehicle-on gating. Unknown quantity — candidates: a
second health metric, a cell-balance/spread figure, an age/cycle-derived
number, or a different SOH basis. Worth tracking over months alongside 451D.
Neighbours: `451C` NRC 0x31 (not implemented), `4440`/`443D` = 0x00.

**`443C`/`4441` = 0x00 EVEN VEHICLE-ON, all 6 rounds.** Contradicts the 09-14
reading where they flickered to 100/100. So their population is rarer than
"vehicle-on" — some other event gates them (post-drive? balancing? a
periodic recompute?). **Do not rely on them.** `451D` remains the single
reliable controller SOH register; this reinforces surfacing only 451D.

**PER-CELL BLOCKS: DEAD END CONFIRMED VEHICLE-ON.** `418D`/`418E`/`418F`/
`4190`/`4191` all return correctly-sized multiframe responses (43/173/58/43/43
bytes) with **entirely zero payloads**, exactly as in sparse mode. Vehicle-on
does NOT unlock them. `4181`/`4240` return a single 0x00 byte. Combined with
the ECU CB gateway block and the 00-FF roster scan finding no hidden cell
module, **per-cell voltages are definitively unreachable via the OBD port** —
the responses are structurally valid but the data is withheld/gated. Only the
DoIP/ENET path remains.

**LIVE PACK VOLTAGE: still not exposed.** `2429`/`2428`/`242D`/`2434` all read
0x5806 = **352.09 V vehicle-on at 100% SOC** — identical to every sparse-mode
read. A real pack at 100% would be ~400 V, so these remain the nominal
constant, not live voltage. (`2489`=0x5804=352.06 V, trivially different —
same constant.) `243D`/`2430` NRC 0x31. **Voltage-sag metric in the drive
report stays uncomputable until DoIP.** Also: `2414`=+0.30 A (idle draw with
car on, positive=discharge — sign convention reconfirmed), `24AA`=165 (small
value, consistent with the demoted uptime-counter reading).

**ECU CB (BSM): all NO DATA vehicle-on** (`F190`, `4369`, `8334`, `43AF`,
`41A3`) — the central-gateway UDS block holds regardless of vehicle state, as
expected. Re-confirmed, no change.

**Net:** the OBD port has now been exhausted for battery data on this vehicle.
Everything further (per-cell, live pack V, SOC, BSM) requires bus access
behind the gateway — the ~$15 ENET/DoIP cable is the only remaining path, and
the transport for it is already built (`lib/protocol/doip.dart`).

## 2026-09-14 leg-1 capacity (final) + leg-2 lost to a logger bug

**LEG 1 (38→73%, vehicle-on charge): 100.6 Ah = 35.40 kWh DC** vs wall meter
**38.29 kWh AC → 92.5% charger efficiency** — now a PLAUSIBLE onboard-charger
number (was 96.5% on the earlier partial cut). 35 dash pts → 2.87 Ah/pt →
~287 Ah ≈ 101 kWh ≈ ~99% of 102 kWh gross. **This is the cleanest single-leg
result and it lands at ~100% SOH with a believable efficiency — best evidence
yet the pack is healthy and the 2414 scale is about right (the earlier "3-5%
high" worry shrinks; residual is within pack-V-vs-nominal uncertainty).**

**LEG 2 (73→79%) NOT USABLE — logger died ~15:31, charge continued ~1h+.**
Final wall meter 47.26 kWh @ dash 79%. The log only holds the first ~4 min of
leg 2 (the −3.7 A trickle right after Ready), so any leg-2 coulomb count is a
massive undercount (the bogus 76% overall / 5.9% leg-2 "efficiency"). Do NOT
use post-15:00 data for capacity. Leg-2 efficiency reconciliation remains open
for a future session.

**TOOLING BUG (fix before next multi-leg session):** the successor-logger
chain used `while pgrep -f chgloghi[.]py; do sleep 60; done; exec …chgloghi.py`
— but that guard command's OWN command line contains "chgloghi.py", so pgrep
matched itself and the successor never fired when the primary died. Also the
primary's own connect-retry exhaustion (link drop when car slept) can kill it
silently. FIX: (a) guard on the python interpreter+script via a PID file, not
a self-matching pgrep; (b) make the logger loop resilient to CONNECT_FAIL
(already retries per-burst, but it exited — add an outer restart wrapper);
(c) verify liveness with a fresh ssh, not the launching one.

**`44C0` = `3A3A3B3B`→`3A3A3A3A`** (58/59 range) — tracks gross SOC, still not
usable-SOC. Consistent with the Aug demotion.

**NET on gross capacity via OBD (user question):** no register on any
gateway-reachable ECU reports pack gross-capacity-in-kWh/Ah directly. `44C5`
first-field is gross-SOC not capacity; SOH% regs are cached-not-live. The
coulomb-count remains THE capacity/SOH source — and it's arguably better
(physical measurement vs BMS model output). We CAN now report **both** a gross
and a usable SOC to the user by decoding `441F` bytes 0/1.
