# Reverse-engineering a new vehicle (e.g. Cadillac Lyriq)

When a vehicle's HV-battery DIDs aren't published, this is the workflow the
toolkit (`lib/tools/`) supports. It is deliberately **read-only** — a `0x22` DID
sweep only *reads* — but run it with the vehicle **stationary and safe**.

## GM / Ultium 29-bit addressing cheat-sheet

GM Ultium ECUs use ISO 15765-4 **29-bit** diagnostic addressing (protocol 7,
`AT SP7`). Layout: `18 <type> <target> <source>`, tester = `F1`.

| Purpose | CAN id | In the scanner |
| --- | --- | --- |
| Functional broadcast (all ECUs) | `18DB33F1` | tester hdr, no filter |
| Physical request to ECU `xx` | `18DAxxF1` | tester hdr |
| Response from ECU `xx` | `18DAF1xx` | response filter |

The **BECM** (Battery Energy Control Module) is the target for HV-battery data;
try `xx = 07` first (`18DA07F1` / filter `18DAF107`), but confirm empirically —
step 1 tells you which `xx` actually answer.

Note: the Ultium pack uses a **wireless BMS** (cells report to the BECM over a
proprietary RF link), so all cell/temperature data is only reachable *through*
the BECM's UDS interface — there is no per-module CAN address to sniff.

Scanner presets ("GM Lyriq — discover ECUs", "GM BECM") pre-fill these.
First sweep `F190–F19F` (identification DIDs: VIN, part/software numbers) — most
ECUs answer at least one, so it's the reliable "who's on the bus" probe before
guessing battery DIDs. Then move to `4000–43FF` / `43xx` / `83xx` on the BECM.

## 0. Get the right adapter

For GM Ultium (Lyriq), the battery ECUs are on **29-bit CAN**. A genuine STN
adapter (**OBDLink CX/MX+**) is strongly recommended; many ELM327 clones cannot
do 29-bit multi-frame ISO-TP and will simply return `NO DATA` for the BMS. The
app flags this case so you don't chase a dead end.

## 1. Confirm the protocol + find responding ECUs

Set `protocol.canFormat = "29bit"` and try the GM tester/response ids. Standard
J1979 mode-01 PIDs (speed `010D`, 12V `0142`) respond even on the Lyriq and are
the confirmed baseline in `signalsets/Cadillac-Lyriq-2025/v01.json` — use them to
prove the transport works before hunting BMS DIDs.

## 2. Sweep DIDs (`UdsScanner`)

```
final scanner = UdsScanner(
  source: bleSource,
  requestHeader: '<GM tester id>',
  responseFilter: '<battery ECU response id>',
  is29Bit: true,
);
final hits = await scanner.sweep(startDid: 0x4000, endDid: 0x4FFF,
    onResult: (r) => print(r));
```

Each DID is classified: `responded` (exists, has data), `outOfRange` (0x31, not
supported), `negativeOther` (e.g. needs a session/security), `noData`,
`malformed`. Only `responded` DIDs are returned as hits. Sweep in blocks; log
everything.

## 3. Identify what each DID means (`correlation.dart`)

A DID that responds is not yet *understood*. To find which DID is SOC (or pack
voltage, current, temperature):

1. Log candidate DID raw values over time while you **read the reference off the
   car's own screen** (SOC %) during a drive or charge.
2. `rankByCorrelation(referenceSeries, {didId: valueSeries, ...})` ranks
   candidates by |Pearson r|. The DID that tracks displayed SOC with r≈1 is your
   SOC signal.
3. Repeat with other references (odometer, speed, ambient temp) to pin more DIDs.

## 4. Solve the scaling

Once a DID is identified, find `div`/`mul`/`sign`/`bix`:
- Compare the raw 16/32-bit field to the known physical value at several points
  to solve for the linear scale (e.g. raw 800 at 80.0 % → div 10).
- For packed multi-value responses (min/max/avg in one DID), vary conditions so
  the fields diverge, then assign `bix` offsets.

## 5. Promote to the signal set

`draftCommandsFromHits(...)` emits placeholder `UNKNOWN_<DID>` commands. Rename,
set the real `fmt`, group, and unit, and move them from the
`_unconfirmed_hv_bms` staging block into `commands`. Record provenance and
confidence. Contribute confirmed sets upstream to
[OBDb](https://github.com/OBDb) under CC BY-SA.

## Safety notes

- Never issue write/coding/routine services during discovery. The toolkit models
  none.
- A malformed flood or repeated `BUS BUSY` means back off — don't hammer the bus.
- Some DIDs only respond in a non-default diagnostic session; needing `0x10` is a
  signal to stop and research rather than brute-force security access.
