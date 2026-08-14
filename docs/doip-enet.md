# DoIP / ENET transport — reaching gateway-routed ECUs

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
