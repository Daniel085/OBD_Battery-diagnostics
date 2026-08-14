# Cadillac Lyriq — consolidated DID map

Master reference combining **our on-vehicle RE** (ECU 40) with the **community
OBDb/Cadillac-LYRIQ** definitions (ECU CB, 1D, and others). All 29-bit, protocol
7 (`ATSP7`). Request `18DA<ecu>F1`, response `18DAF1<ecu>`, functional `18DB33F1`.

Sources: OBDb/Cadillac-LYRIQ test cases (github.com/OBDb) + our Pi captures.
Formulas marked ✓ are derived from OBDb sample response/value pairs or confirmed
on our vehicle; ⚠ = ours, hypothesis.

## ⚠️ The ECU CB gateway limitation (root cause found)

**ECU CB (BSM — Battery System Manager) is blocked at the gateway for UDS.**
Proven on-vehicle by comparing who answers each request type:

| Request | CB answers? |
| --- | --- |
| `0100` (J1979 mode 01, functional) | ✅ **yes** |
| `22F190` / any `22xxxx` (UDS) | ❌ **no** |

So the vehicle's central gateway **bridges legislated OBD (J1979) frames to/from
CB but filters UDS (service 0x22) requests to it.** This is not an adapter defect
and is **not fixable via AT headers/flow-control/session** (12+ combinations
tried) — a better ELM327 (OBDLink CX) won't change it either, because the block
is on the *request type through the gateway*, not the adapter.

The OBDb `DACB.*` SOC/cell captures therefore came from a tool that bypasses the
gateway (different OBD pin / internal bus tap / GM MDI2), not a standard
OBD-port ELM327. Reaching CB needs bus access behind the gateway (hardware), not
software.

**Workaround:** SOC can be estimated from the confirmed **pack voltage**
(`1D.2233E5`) via the Ultium voltage↔SOC curve (≈268 V at 0%, ≈400 V at 100%),
so CB is not strictly required for a useful SOC readout.

## Battery — ECU CB (DACB) — the canonical BMS (gateway-blocked for UDS)

| Signal | DID | Formula | Source |
| --- | --- | --- | --- |
| **SOC (standard)** | `222B43` | `byte[0] / 255 × 100` % | ✓ OBDb (exact on 5 samples) |
| **SOC (high-def)** | `2227C6` | `u16 / 65535 × 100` % | ✓ OBDb (consistent w/ std) |
| **Cell V avg** | `222AF5` | `u16[0] / 10000` V (~3.75 V) | ✓ OBDb |
| **Cell V max** | `222AF5` | next u16 / 10000 V | ✓ OBDb (offset TBC on-car) |
| **Cell V min** | `222AF5` | next u16 / 10000 V | ✓ OBDb (offset TBC on-car) |

Response examples: `222B43` → `18DAF1CB101D622B43 87 00 86 …` (0x87=135 → 52.94%);
`2227C6` → `18DAF1CB056227C6 83B7` (→ 51.45%); `222AF5` (multiframe) →
`…622AF5 9270 …` (0x9270 = 3.749 V).

## Battery — ECU 1D (DA1D)

| Signal | DID | Formula | Source |
| --- | --- | --- | --- |
| **Pack voltage** | `2233E5` | TBD (read on-car; expect ~355–400 V) | community (formula unread) |

## Battery — ECU 7E4 / 7EC (11-bit) = same as 29-bit ECU 40

OBDb lists these as documented-but-**uncaptured** (no test cases yet) — so reading
them on our car is NEW data worth contributing upstream. Address via 11-bit
(`ATSH 7E4`, no 29-bit) OR 29-bit `18DA40F1` (7E4↔40 are the same ECU).

| Signal | DID | Note |
| --- | --- | --- |
| **HV battery temperature** | `22434F` | We already read `434F`=0x46 (70) on ECU 40 — same ECU. Confirms mapping. |
| **AC/HV charging voltage + CURRENT** | `224368`–`22436C` | **The pack current we couldn't find** — a 5-DID block. Read while charging. |
| **Charge mode** | `224373` | enum |

## 96 CMU cell voltages — ECU 7E7 (11-bit)

OBDb: `224181`–`224240` = 96 individual cell/CMU voltages (documented, uncaptured).
These map to the `4181`–`4240` multiframe blocks we found on ECU 40 (mostly zero
when idle/not balancing). Read via `ATSH 7E7` (or 29-bit equivalent) when active.

## Battery — ECU 40 (DA40) — our on-vehicle RE

| Signal | DID(s) | Formula | Source |
| --- | --- | --- | --- |
| Module/section voltage ×3 | `416C` `416D` `416E` | `u16 / 100` V (~51 V) | ✓ ours (moved w/ charge) |
| Temperatures | `4127` `4124` `40E5` `40E6` | `u16 / 32` °C (~23–33 °C) | ✓ ours (rose w/ charge) |
| SOC candidate | `406E` | `byte` (=47 @ 49%) | ⚠ ours (unmoved) — prefer DACB SOC |
| Energy counters (SOH?) | `415B` `415C` | `u32` | ⚠ ours |
| Per-cell/module blocks | `418D`–`4191`, `424A`–`424C` | multiframe arrays | ⚠ ours (needs ISO-TP) |

## 96 CMU cell voltages

OBDb documents `CADILLAC_HVBAT_CMU01_VOLT`…`CMU96_VOLT` (96 = the 96S pack). These
are the per-cell voltages — location is the multiframe `222AF5`-family / `424x`
blocks. DID/offset mapping still to pin down (many read zero unless balancing).

## Other useful (non-battery) DIDs from OBDb

- `DA1A.22448F` — odometer
- `DA18.221940` — transmission/drive-unit fluid temp · `DA18.221B30` — gear
- `DA11.22153E` — oil temp · `DA11.22002F` — aux voltage/fuel-level
- `DA28.224A7A` — tire speed sensors · `DA28.224C2D` — steering angle
- `DB33.01xx` — standard J1979 (mostly EV placeholders; `0142` voltage real)

## Wake-and-read priority list (next live pass)

Car must be in **Ready** (ECU CB/1D/40 sleep fast when idle). Read in this order:
1. `18DACBF1` → `222B43` (SOC, byte0/255×100) and `2227C6` (SOC HD, u16/65535×100)
   — verify ~49% on our car
2. `18DACBF1` → `222AF5` (cell V avg/max/min, u16/10000 V)
3. `18DA1DF1` → `2233E5` (pack voltage — derive formula from the reading)
4. `18DA40F1` → `224368`–`22436C` (**pack current / charging** — the missing
   signal; read while charging so it's non-zero, derive formula, diff vs idle)
5. `18DA40F1` → `22434F` (HV battery temp — cross-check vs our `4127`/`40E5`)
6. `18DA40F1` → `224181`–`224240` sample (96 CMU cell voltages, multiframe) —
   read a few while pack is active
7. Re-confirm our `416C`/`4127`/`40E5` module V + temps

Everything here except our own ECU-40 findings is documented-but-**uncaptured**
in OBDb — reads become upstream contributions.
