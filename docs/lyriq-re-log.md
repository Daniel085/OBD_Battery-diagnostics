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

## NOT yet identified

- **SOC / pack voltage / pack current / cell voltages / temperatures.** These are
  the meaty analog (2-byte+) signals and were **not** positively matched to a DID
  this session. Reference point captured for correlation: **SOC = 49%** on the
  dash (raw `0x31`), plus a request to find coolant/battery temps.

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
