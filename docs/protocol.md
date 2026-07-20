# Protocol layer design

How a request in a signal set becomes a decoded physical value, and where each
responsibility lives. All of this is pure Dart (`lib/protocol`, `lib/engine`) so
it runs under `dart test` with no device or car.

## Request path

For a `Command` like `{ hdr: "6F1", rax: "607", eax: "07", cmd: { "22": "DDBC" } }`:

1. **Engine** builds the UDS message bytes: `buildRequest(0x22, [0xDD, 0xBC])`
   → `[0x22, 0xDD, 0xBC]`.
2. **Transport** (`ElmBleSource`) configures the ELM327 for this command:
   - `AT SH 6F1` — set the transmit header (tester address).
   - `AT CRA 607` — filter to only the SME's response id.
   - BMW extended addressing: the `eax` (`07`) is sent as the first payload byte
     on the wire per BMW's tester protocol (handled in the ELM source, not here).
   - Send the message as an ASCII hex string; read frames until the `>` prompt.
3. On a genuine STN/ELM327, the adapter performs ISO-TP flow control itself and
   returns the reassembled ASCII hex. On adapters/paths where it does not (raw
   CAN, sniffing, some clones), the **ISO-TP reassembler** (`isotp.dart`) does it.

## Response path

```
raw frames ──▶ IsoTP reassemble ──▶ UDS parseResponse ──▶ SignalFormat.decode ──▶ value
 (CAN data)      (isotp.dart)          (uds.dart)            (formula.dart)
```

1. **ISO-TP reassembly** (`reassemble` / `IsoTpReassembler`): turns one Single
   Frame, or a First Frame + Consecutive Frames, into one contiguous message.
   Handles 12-bit length, sequence checking, last-frame padding trim, and CAN-FD
   escape-length single frames. Addressing width (11/29-bit) does not change this
   layer — it only changes the CAN id, which is the transport's concern.
2. **UDS parse** (`parseResponse`): 
   - Detects negative responses (`0x7F <svc> <nrc>`) and throws
     `UdsNegativeResponse` (with `isPending` for the `0x78` "response pending").
   - Verifies the positive-response service byte (`request | 0x40`).
   - Strips the echoed identifier (2 bytes for `0x22`, 1 for `0x01`) and returns
     the remaining **data payload**.
3. **Formula decode** (`SignalFormat.decode`): extracts a big-endian bit field
   `[bix, bix+len)` from the data payload, optional two's-complement sign, then
   scales `(raw * mul / div) + add`.

## The `bix` contract

`bix` is the bit offset **into the data payload** — i.e. *after* the service echo
and echoed identifier are removed. This is the single most error-prone detail in
OBD decoding, so it is fixed by convention here and enforced by tests. Example
for SOC (`22 DDBC`):

```
wire response : 62 DD BC 03 20
                └┬┘ └─┬─┘ └─┬─┘
              service DID   data payload  ← SignalFormat sees only [0x03,0x20]
                            bix=0, len=16, div=10 → 0x0320/10 = 80.0 %
```

## Read-only invariant

Only these services are modelled and issued:
- `0x22` ReadDataByIdentifier
- `0x19` ReadDTCInformation
- `0x01` J1979 current data
- `0x10` DiagnosticSessionControl (only if a read requires a non-default session)

No `0x2E` WriteDataByIdentifier, `0x31` RoutineControl, `0x14` ClearDTC, or coding.
This is a safety property, not a limitation to be relaxed casually.

## Testing without a car

`ReplaySource` (Phase 1) plays recorded request→response captures, so the whole
decode path is covered in CI. Captures come from the ELM327-emulator and, later,
from real vehicle logs. See `test/uds_decode_test.dart` for the end-to-end path
exercised against the BMW 330e signal set with synthetic SME responses.
```
