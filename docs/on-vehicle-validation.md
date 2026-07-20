# On-vehicle validation checklist

The software path is complete and tested offline. These steps confirm it against
real vehicles and turn the "inferred / unconfirmed" signals into trusted ones.
Do all of this with the vehicle **stationary, in a safe location**, ignition on.

## BMW 330e (2018, F30)

1. Pair a BLE ELM327 adapter; in the app select **BMW 330e**, Scan, connect.
2. Confirm the dashboard populates SOC / SOH / pack voltage / current.
3. **Validate the inferred offsets** (the reason values aren't yet trusted):
   - `DDC0` cell temperature min/max — confirm the two 16-bit fields are ordered
     min-then-max and scaled ÷100 °C. Compare against ambient / a known warm pack.
   - `DFA0` cell voltage min/max/avg — confirm field order and ÷10000 V scaling;
     min ≤ avg ≤ max must hold.
   - `6335` SOH — confirm the value lands at payload bit offset 24 (byte 3).
4. Cross-check SOC against the car's own iDrive energy display.
5. At rest, confirm cell spread (max−min) is small (~≤20 mV on a healthy pack).
6. If any field is shifted/misscaled, correct `bix`/`div`/`sign` in
   `signalsets/BMW-330e-2018/v01.json`, bump to `v02`, and note it in provenance.

## Cadillac Lyriq (2025, Ultium)

The HV-BMS DIDs are unknown; this is discovery, not validation.

1. Prefer an **OBDLink CX/MX+** (29-bit multiframe). Select **Cadillac Lyriq**.
2. Confirm the J1979 baseline (speed `010D`, 12V `0142`) responds — proves the
   transport works.
3. Open the **DID Scanner**, enable **29-bit CAN**, set the GM battery-ECU
   tester/response ids, and sweep DID ranges in blocks. Record responders.
4. Log candidate DID values while reading SOC % off the car's display; use the
   correlation ranking (see `docs/reverse-engineering.md`) to identify SOC first,
   then voltage/current/temps.
5. Solve scaling, promote confirmed signals from `_unconfirmed_hv_bms` into
   `commands`, and contribute the set upstream to OBDb (CC BY-SA).

## Adapter GATT note

If the app connects but no notifications arrive, the adapter likely uses a
different GATT layout. Try the Nordic-UART config
(`ElmBleConfig.nordicUart()`) vs the default FFE0/FFE1 clone layout in
`lib/transport/elm_ble_source.dart`.
