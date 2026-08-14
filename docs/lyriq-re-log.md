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
