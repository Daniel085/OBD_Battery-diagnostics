# Vehicles imported from OBDb

Some vehicles in the app come straight from the community data at
<https://github.com/OBDb> (CC BY-SA 4.0), not from our own reverse
engineering. This page says how that works and what each imported vehicle
is worth today.

## How an import works

    python3 tools/obdb-import/import_obdb.py tools/obdb-import/<vehicle>.map.json \
        --repo OBDb/<Repo>=<path to a checkout of that repo>

- **The map file** (`tools/obdb-import/*.map.json`) is the only hand-written
  part. It lists the OBDb signals worth polling for battery diagnostics and
  gives each a group and, where the app's logic looks for one, its canonical
  id (`HVBAT_SOC`, `HVBAT_SOH`, `HVBAT_VOLTAGE`, `HVBAT_CURRENT`,
  `HVBAT_CELLTEMP_MIN/MAX/AVG`, `HVBAT_AH_DISCHARGED`, `HVBAT_CAPACITY_AH`,
  `LVBAT_*`, `MOTOR_*`, `ODOMETER`). It also records the OBDb commit used.
- **Requests, bit layouts and scaling are OBDb's, unchanged.** The tool only
  renames units to the app's, rescales Fahrenheit signals to Celsius, turns
  `offon` and enumerations into named values, and keeps a command's `freq`
  when it is above 1 s.
- **Signals borrowed from a sibling model** are marked in the map with
  `"unconfirmed": true` and come out with a `?` unit and "(unconfirmed)" in
  the name, like any other unverified signal in this project.
- **Fixtures.** OBDb repos carry replies captured on real vehicles with the
  values they should decode to (`tests/test_cases/<year>/commands`). The tool
  turns those into `test/fixtures/obdb/<vehicle>.json`, and
  `test/obdb_import_test.dart` replays every one through the app's full
  decode path. That proves our decoder agrees with OBDb; it does not prove a
  signal is what OBDb says on every vehicle.
- To add a vehicle: write a map, run the tool, add the vehicle to
  `SignalSetRepository.catalogue` and to `pubspec.yaml` assets. To refresh
  one: pull the OBDb repo, update the commit in the map, rerun.

What an imported vehicle does not get automatically:

- **A capacity test.** It needs `pack.ratedKwh` and `pack.nominalVoltage` in
  the signal set; without them the app does not offer the test (it used to
  grade every vehicle against the Lyriq's 102 kWh).
- **A cycle count from a rated capacity.** With no `pack.ratedAh` the app
  divides lifetime throughput by the capacity the vehicle itself reports
  (`HVBAT_CAPACITY_AH`) when there is one, and says so on screen.
- **A demo mode.** The demo buttons are for the two simulated vehicles.
- **A checked current sign.** The app needs `HVBAT_CURRENT` positive on
  discharge. OBDb does not record the sign convention.

## Ford F-150 Lightning (2022–2025)

`signalsets/Ford-F-150-Lightning-2022/v01.json`, from
`OBDb/Ford-F-150-Lightning` @ `bb26b0f293` (2026-11-13). 58 requests, 60
signals, chosen from OBDb's 144:

| Module | Request → reply | What |
|---|---|---|
| Battery controller (BECM) | `7E4` → `7EC` | displayed and BMS charge level, state of health, pack voltage and current, energy, temperatures (min/max/avg, coolant inlet), module voltage min/avg, charge spread, battery age, reported capacity (Ah), lifetime charge out, leakage voltages, charge limits and status |
| Charger (SOBDM) | `7E2` → `7EA` | AC input voltage/current/frequency, pilot, proximity, charger type, coupler temperatures, DC status, power available |
| Drive unit | `7E6` → `7EE` | motor speed, torque, coil and inverter temperature, gear, battery thermal mode, coolant heater |
| DC/DC | `746` → `74E` | on/off, 12 V-side and HV-side current |
| Body module (12 V monitor) | `726` → `72E` | 12 V battery charge, voltage, current, age, standby current |
| Cluster | `720` → `728` | odometer |
| DC fast-charge controller | `6F5` → `6FD` | charger maximum current and voltage |

Left out: tyre pressures, wheel speeds, steering, driver-assist, and
everything OBDb marks as debug.

Status: **not read on a truck by this project.** All 58 requests have OBDb
captures from 2022–2025 trucks (175 replies in the fixtures) and decode to
OBDb's values. Before trusting it on a truck:

1. **Current sign.** Plug in and charge: `HVBAT_CURRENT` must be negative.
   Drive: positive. If reversed, add `"mul": -1` in the map and rerun.
2. **`fcm1`.** OBDb flags 12 of these requests as needing "flow-control
   mode 1". The flag is carried into the signal set but the app does not act
   on it. The replies are single frames, so it may not matter; if those
   requests alone fail, this is why.
3. **Poll time.** 58 requests per full refresh, fewer once the slow ones
   (`freq`) have been read. Measure it with a real adapter.
4. **What `485C` "battery capacity" is** (rated or present). OBDb's 2023
   capture reads 373.9 Ah. The cycle count divides by it.
5. A capacity test needs the pack's rated kWh and nominal voltage, which
   differ between the standard and extended-range packs.

## Ford F-150 PowerBoost hybrid (2021+)

`signalsets/Ford-F-150-Hybrid-2021/v01.json`. **OBDb's F-150 data has no
hybrid-battery signals at all**: no request to the battery controller, and
no reply from it in any 2021–2025 capture. So the set is two different
things:

- **From `OBDb/Ford-F-150` @ `7b0146e384` (2026-11-15), for 2021+ trucks:**
  12 V battery charge and age (body module `726`), odometer, speed, fuel
  level, distance to empty, engine coolant temperature, engine speed. 32
  captured replies in the fixtures. The 12 V battery age is OBDb's value in
  days, shown in hours so the app can display it as years.
- **Guessed, from `OBDb/Ford-Maverick` @ `0417358dee` (2026-11-15):** the
  hybrid battery signals. Ford's battery controller answers the same
  identifiers at `7E4` on the Maverick hybrid, the Mustang Mach-E and the
  Lightning (`4801` charge, `480D` voltage, `480B` current, `4800`/`4808`
  temperatures, `490C` state of health, `485D` lifetime charge out, `4810`
  age, `4840`/`4841` module voltages), so the PowerBoost probably does too.
  All 15 are marked unconfirmed. A request the truck rejects is skipped and
  shows nothing.

### First session with the truck

A hybrid F-150 is available to us, so this is the next on-vehicle session.
It has to be done **with the phone alone** (no Pi at the truck), so the app
is the capture rig:

- **Everything is recorded as it happens.** From the moment the app connects
  to a real adapter, each command it sends and the raw reply go into a
  session file on the phone (`captures/<date>-<time>_<vehicle>_session.txt`
  in the app's documents), flushed every two seconds. Nothing has to be
  tapped for that, and it covers the dashboard's reads, the signal check,
  sweeps, the terminal and drive mode.
- **Signal-check reports and DID sweeps are saved as their own files** when
  they finish (also when stopped half way).
- **The phone does not auto-lock while connected.** Do not lock it or switch
  to another app during a sweep: iOS suspends the app and the sweep stops.
- **Getting the files home:** Home screen → folder icon ("Captures") lists
  them with share buttons. Or leave them: with the phone near the Mac,

      xcrun devicectl device copy from --device <phone udid> \
          --domain-type appDataContainer \
          --domain-identifier com.obddiag.obdBatteryDiagnostics \
          --source Documents/captures --destination captures/phone/

  copies the whole folder. `Recording.parse`
  (`lib/transport/recording_source.dart`) reads a session file back into
  exchanges with their addressing; `SignalCheck.repliesIn` does the same
  for a report. Both feed a `ReplaySource`.

At the truck: adapter in the OBD port, truck in Ready (not just accessory:
the battery controller may sleep otherwise), parked.

1. Pick "Ford F-150 PowerBoost hybrid", connect. The dashboard shows
   whatever answers. Leave it a minute: that is the first recording.
2. **More → Signal check → Check 21 requests.** It sends each request once
   and lists it as answered, rejected (with the code) or silent, with the raw
   reply. The report is saved on the phone when it finishes.
3. If `7E4` answered anything: **More → DID scanner**, tap the `7E4 → 7EC`
   preset (range `4800`–`49FF`, the block Ford's battery controllers use),
   run the sweep. It lists everything the controller offers in that block,
   including what the Maverick list does not have. Then run the same sweep
   a second time after step 6: the bytes that changed are the live values.
4. If `7E4` was silent on everything, the battery controller may sit at
   another address on this truck. **More → Adapter terminal**, then type
   `ATSH7DF`, `ATCRA`, `22F190`: each reply line starts with the id of a
   control unit that answered (the adapter shows `7E8`–`7EF` for this
   broadcast address). Not tried on a Ford by us.
5. Note what the dash shows at the same time: hybrid battery gauge (it has
   no number, so roughly), odometer, fuel range. Those are the cross-checks.
   A photo of the dash is enough; the recording has the time of every read.
6. Current sign, if `HVBAT_CURRENT` answers: with the dashboard open, creep
   forward on the electric motor (must read positive), then brake (regen,
   negative). The recording keeps the values; no need to watch the phone.
7. Disconnect in the app before unplugging: that closes the session file.

While the signal check, the scanner or the terminal has the adapter, the
dashboard's own reads pause, and they set the adapter up again afterwards.

Afterwards: signals that answered and match the dash lose their marks in the
map file (delete `"unconfirmed": true`, or set `"from"` to the F-150 repo
once OBDb has them); requests the truck rejects come out of the map. The
confirmed ones are worth contributing back to OBDb's F-150 set, which has
none.
