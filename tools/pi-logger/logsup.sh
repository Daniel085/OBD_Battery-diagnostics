#!/usr/bin/env bash
# Self-restarting supervisor for the OBD charge/drive logger.
#
# Replaces the old `while pgrep -f chgloghi[.]py; do sleep; done; exec ...`
# chain, which had two bugs:
#   1. the guard's own command line contained "chgloghi.py", so pgrep matched
#      ITSELF and the successor never fired when the primary died;
#   2. the primary Python exited on connect-retry exhaustion (car sleeping /
#      BLE link lost) with nothing to restart it.
#
# This uses an flock'd lock file for single-instance guarding (no self-matching
# pgrep) and an outer loop that restarts the logger if it exits, until a
# deadline or a stop file appears.
#
# Usage: logsup.sh <logger.py> <total-hours>
# Stop early:  touch ~/obdbridge/logger.stop
set -u

SCRIPT="${1:?usage: logsup.sh <logger.py> <hours>}"
HOURS="${2:?usage: logsup.sh <logger.py> <hours>}"
PY="$HOME/obdbridge/venv/bin/python"
LOCK="$HOME/obdbridge/logger.lock"
STOP="$HOME/obdbridge/logger.stop"
SUPLOG="$HOME/obdbridge/logsup.log"

# Single-instance guard via flock on a dedicated fd. If another supervisor
# already holds the lock, exit immediately — no pgrep, so nothing can match
# its own command line.
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "$(date '+%F %T') another supervisor holds $LOCK; exiting" >>"$SUPLOG"
  exit 0
fi

rm -f "$STOP"
END=$(( $(date +%s) + $(printf '%.0f' "$(echo "$HOURS * 3600" | bc)") ))
echo "$(date '+%F %T') supervisor start: $SCRIPT for ${HOURS}h (pid $$)" >>"$SUPLOG"

while [ "$(date +%s)" -lt "$END" ]; do
  if [ -f "$STOP" ]; then
    echo "$(date '+%F %T') stop file present; exiting" >>"$SUPLOG"
    break
  fi
  echo "$(date '+%F %T') launching logger" >>"$SUPLOG"
  # The logger writes its own data file; its stdout/stderr go to the sup log.
  "$PY" "$SCRIPT" >>"$SUPLOG" 2>&1
  rc=$?
  echo "$(date '+%F %T') logger exited rc=$rc" >>"$SUPLOG"
  # Brief backoff so a hard-failing logger can't spin; also lets the BLE
  # stack settle before the next gatttool connect.
  sleep 15
done
echo "$(date '+%F %T') supervisor done" >>"$SUPLOG"
