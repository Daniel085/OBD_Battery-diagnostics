# Pi charge/drive logger

Runs on the Raspberry Pi BLE bridge (`daniel@pi.local`) to log Lyriq OBD
registers over the Viecar during charge or drive sessions. This is the
data-capture rig behind the on-vehicle RE (`docs/lyriq-re-log.md`); it is not
part of the app.

## Files

- `obdlogger.py` — one logging "shift": connect, read a DID set on a cadence,
  append timestamped rows. Config via env:
  - `OBD_LOGFILE` (required) — data file to append to
  - `OBD_SHIFT_S` (default 900) — shift length; the supervisor owns the total
  - `OBD_CADENCE_S` (default 30) — seconds between sample bursts
  - `OBD_PROFILE` — `charge` (default) or `drive` (adds dynamics ECU, drops
    the slow charge/SOH registers for a faster power trace)
  - `OBD_STOPFILE` (default `~/obdbridge/logger.stop`) — touch to stop cleanly
- `logsup.sh <logger.py> <hours>` — self-restarting supervisor.

## Why a supervisor (the 2026-09-14 bug)

The previous approach chained loggers with
`while pgrep -f chgloghi[.]py; do sleep; done; exec ...`. Two failures cost us
the leg-2 capture:

1. **Self-matching guard.** The guard command's own command line contained
   `chgloghi.py`, so `pgrep` matched *itself* and the successor never fired
   when the primary died.
2. **No restart.** The primary Python exited on connect-retry exhaustion (car
   asleep / BLE link lost) with nothing to relaunch it.

`logsup.sh` fixes both: single-instance guarding is an `flock` on a lock file
(no pgrep, nothing to self-match), and an outer loop relaunches the logger
until a deadline or the stop file. `clear_link()` swallows all errors so a
hung `bluetoothctl` can never crash a shift into a relaunch spin.

## Run

```bash
# Charge session, 8 hours, on the Pi:
OBD_LOGFILE=~/chglog_$(date +%F).txt \
  setsid nohup bash ~/obdbridge/logsup.sh ~/obdbridge/obdlogger.py 8 \
  >/dev/null 2>&1 < /dev/null &

# Drive session, faster cadence, 2 hours:
OBD_LOGFILE=~/drive_$(date +%F).txt OBD_PROFILE=drive OBD_CADENCE_S=2 \
  setsid nohup bash ~/obdbridge/logsup.sh ~/obdbridge/obdlogger.py 2 \
  >/dev/null 2>&1 < /dev/null &

# Stop early:
touch ~/obdbridge/logger.stop

# Verify liveness from a FRESH ssh (not the launching one):
pgrep -af obdlogger
```
