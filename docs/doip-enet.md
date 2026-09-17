# DoIP / ENET transport — reaching gateway-routed ECUs

## RESEARCH 2026-09-17 — is DoIP actually viable on the Lyriq?

Triggered by a fair challenge: "why can't the Bluetooth adapter do this, and
how is Ethernet magic?" Short answer: the medium isn't magic, the **access
path** is — but the picture is more mixed than earlier notes implied.

**Why no CAN adapter (BT or otherwise) can reach the blocked data.** The
Viecar/OBDLink/etc. all land on OBD pins 6/14 = the single CAN segment the
central gateway exposes outward. We proved on-vehicle the gateway forwards
J1979 broadcasts to ECU CB but silently drops UDS `22` to it (12+ header/
flow-control/session combos tried). A better CAN adapter sits on the *same
pins* behind the *same filter*: it fixes 29-bit multiframe reliability, not
routing. Confirmed independently: per-cell blocks return correctly-sized
all-zero frames even vehicle-on (2026-09-17 sweep) — the data is withheld,
not merely unreachable.

**DoIP is a different gateway port, not a faster wire.** ISO 13400-4 defines
two J1962 pinouts: Option 1 = pins 3(RX+)/11(RX-)/12(TX+)/13(TX-), Option 2 =
1/9/12/13; **pin 8 is the activation line** — the tester senses resistance
between pin 8 and pin 5 (signal ground) to detect which option is in use, then
applies +5 V to pin 8 to request the Ethernet link. Crucially the OBD
connector carries **standard 100BASE-TX**, not BroadR-Reach/100BASE-T1 (that's
only used ECU-to-ECU inside the car, needing a media converter like a
RAD-Moon). **So the earlier "GM needs an expensive BroadR-Reach adapter"
caution was WRONG** — a passive ENET-style cable is the right class of
hardware.

**GM Global B DOES route Ethernet through the OBD connector — confirmed by
tooling.** Intrepid sells a "Global B OBD Cable" whose published pin mapping
includes **ETH TX+, ETH TX-, ETH RX+, ETH RX-** on J1962, alongside the CAN
channels. GM's own MDI 2 is documented as handling **CAN FD and DoIP natively
for Global B**, explicitly including Lyriq / Blazer EV / Silverado EV. So the
physical path exists on this platform.

**The real risk is authentication, not wiring.** Global B is GM's security
architecture: signed/authenticated module software, inter-module message
authentication, and a secure gateway that authenticates the diagnostic tool.
Aftermarket tools are documented as blocked from bi-directional functions,
DTC clearing and calibrations on SGW-equipped vehicles; GM holds
challenge-response patents for securing diagnostic services. Our own ECU 53
result (rejects session `1003` → `7F1012`) shows GM does enforce security
access on this car. **DoIP routing activation may well require credentials we
do not have.** Reading (service `22`) is a softer ask than programming, so it
may pass where writes would not — but that is a hypothesis, not a finding.

**No community precedent found.** Searches turned up no report of anyone
reading Ultium per-cell data over DoIP with aftermarket hardware. What did
turn up: Ultium uses a **wireless BMS** (cells talk to the BMS over RF, not
wires), and a DIY-EV forum thread notes interfacing with it as factory-
intended is "extremely unlikely". That is a second, independent reason
per-cell data may be architecturally unavailable regardless of transport.

**VERDICT — worth trying, but not a sure thing.** Cost is low (a passive
ENET-class cable) and our DoIP transport is already written and
offline-tested. But expect a real chance of failure at routing activation
(security) or of the data simply not being exposed (wireless BMS). Do NOT
present this to users as a promised capability.
**Cheap verification first, before buying:** (1) inspect the Lyriq's J1962 for
populated pins 3/11/12/13 (and 1/9), (2) measure resistance pin 8 → pin 5 to
see whether an activation line is present and which ISO option it indicates.
Empty pins or no activation resistance = path closed, no purchase needed.

## Original notes

Both target cars gate their deep BMS off the OBD-II CAN pins:
- **BMW 330e** — the SME (SOH, per-cell voltages, cell temps) isn't bridged to
  the port. ISTA reaches it over **ENET** (Ethernet-to-OBD).
- **Cadillac Lyriq** — the BSM (SOC, 96 cell voltages) is gateway-blocked for UDS.

The common unlock is **DoIP** (Diagnostics over IP, ISO 13400): UDS wrapped in a
small Ethernet/TCP header and **routed by the vehicle gateway to the target
ECU**, including ECUs the CAN pins never expose. That's exactly what BMW's ENET
cable + ISTA do — and it's just an open protocol plus a ~$15 passive cable, not a
proprietary black box.

## What we built

| Piece | File | Role |
| --- | --- | --- |
| DoIP framing | `lib/protocol/doip.dart` | header, routing-activation, diagnostic-message encode/decode (pure bytes) |
| UDS transport seam | `lib/transport/uds_transport.dart` | `request(target, uds) → response bytes` — the abstraction ELM and DoIP share |
| DoIP transport | `lib/transport/doip_source.dart` | TCP connect → routing activation → diagnostic message exchange, ack/nack + alive-check handling |
| TCP socket | `lib/transport/tcp_doip_socket.dart` | thin dart:io adapter (device only) |
| Engine client | `lib/engine/uds_diagnostics_client.dart` | drives a signal set over any `UdsTransport`, same decode path as ELM |

All protocol logic is unit-tested against a scriptable fake gateway
(`test/doip_test.dart`) and the full decode path is proven end-to-end
(`test/uds_doip_client_test.dart`) — no vehicle needed to develop.

## Using it on a BMW (ENET)

1. **Cable:** an ENET (Ethernet-OBD) cable — passive, wires OBD pin 8 to RJ45.
2. **Link:** plug into the car's OBD port and the Pi's/host's Ethernet. The
   gateway presents a link-local address.
3. **Config:** `DoipConfig(host: <gateway ip>, port: 6801, testerAddress: 0x0E00,
   gatewayTarget: 0x0010)` (BMW defaults; `DoipConfig.standard()` for ISO port
   13400).
4. **Read the SME:** point `UdsDiagnosticsClient` at the existing BMW-330e signal
   set — the `6F1/607` SME DIDs (SOH `6335`, cell V `DFA0`, etc.) that returned
   NO DATA over the OBD-port ELM327 should now answer through the gateway.

## Status / caveats

- The transport, framing, routing activation, and decode path are **built and
  tested offline**. Confirming against a real ENET-connected BMW is the remaining
  on-vehicle step (host addresses / exact tester+target logical addresses vary by
  chassis and may need a short discovery).
- Some ECUs still require a **UDS diagnostic session / security access** beyond
  routing activation; that is a separate layer (see the Lyriq ECU 53 note in
  `lyriq-did-map.md`).
