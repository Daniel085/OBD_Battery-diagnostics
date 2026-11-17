"""BMW 330e SME charge logger. READ-ONLY (UDS 0x22 only, via sme_probe).

Logs the SME through one plug-in charge so the charge can be coulomb-counted
(capacity -> a ground truth for the SOH figure) and the counter candidates in
docs/bmw-330e-sme.md can be checked before/after one known event.

Run ON THE PI, car plugged in and charging (engine ECU asleep is fine):
    OBD_LOGFILE=~/bmw_chg_$(date +%F).txt python3 sme_chglog.py

  every CADENCE_S (20):  DD69 current, DD66 pack V, DDBC SOC, DDC0 temps, DFA0
  every SLOW_S (600):    the counter / per-module set (SLOW below)
  stops by itself when the charge is over: current under 0.3 A, or the SME
  silent, for END_QUIET_S (600) after charging was seen; or at MAX_H (6) hours;
  or when OBD_STOPFILE (~/bmw-sme-probe/chglog.stop) exists.
The counter set is read at start, the moment the current first stops, and at
exit. Lines are raw hex (`HH:MM:SS DID=hex ...`); `-` = no reply.
"""
import os
import subprocess
import sys
import time

import pexpect

import sme_probe as p

LOGFILE = os.path.expanduser(os.environ["OBD_LOGFILE"])
STOPFILE = os.path.expanduser(
    os.environ.get("OBD_STOPFILE", "~/bmw-sme-probe/chglog.stop"))
CADENCE_S = float(os.environ.get("OBD_CADENCE_S", "20"))
SLOW_S = float(os.environ.get("OBD_SLOW_S", "600"))
END_QUIET_S = float(os.environ.get("OBD_END_QUIET_S", "600"))
MAX_H = float(os.environ.get("OBD_MAX_H", "6"))

FAST = ["DD69", "DD66", "DDBC", "DDC0", "DFA0"]
SLOW = ["DFAC", "DF67", "DF62", "DF60", "DD8E", "DF76", "DFAA", "DFAD",
        "DFE2", "DDC9",
        # 2026-11-15: Ah in / Ah out candidates (little-endian As?), contactor
        # count, resistance health. One charge should move DD73 by the
        # coulomb count and DF60's first word by the hours spent charging.
        "DD73", "DD74", "DD63", "DDB6"]

LOG = open(LOGFILE, "a")


def log(s):
    LOG.write(s + "\n")
    LOG.flush()
    print(s, flush=True)


def read(child, did):
    msg = p.uds_message(p.cmd(child, "22" + did, 8.0, quiet=True))
    if msg is None or msg[0] != 0x62:
        return None
    return msg[3:]


def row(child, dids, tag=""):
    vals = {d: read(child, d) for d in dids}
    log(time.strftime("%T") + tag + " " + " ".join(
        d + "=" + (v.hex() if v is not None else "-") for d, v in vals.items()))
    return vals


def clear_link():
    try:
        subprocess.run(["bluetoothctl", "--timeout", "1", "disconnect", p.MAC],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=6, check=False)
    except Exception:
        pass


def open_link():
    clear_link()
    child = pexpect.spawn(f"gatttool -b {p.MAC} -I", encoding="utf-8",
                          timeout=20, codec_errors="replace")
    if not p.connect(child):
        child.close(force=True)
        return None
    for c in ["ATZ", "ATE0", "ATL0", "ATS0", "ATH1", "ATSP6"]:
        p.cmd(child, c, 3.0 if c == "ATZ" else 1.5, quiet=True)
    p.ext_mode(child, 0x07)
    return child


def main():
    p.LOG = open(os.devnull, "w")  # sme_probe.out() is unused but needs a sink
    deadline = time.time() + MAX_H * 3600
    log("=== bmw charge log start %s cadence=%.0fs" %
        (time.strftime("%F %T"), CADENCE_S))
    child = None
    seen_charge = False
    quiet_since = None   # when current first read ~0 / SME went silent
    after_read = False
    next_slow = 0.0
    misses = 0
    try:
        while time.time() < deadline and not os.path.exists(STOPFILE):
            if child is None:
                child = open_link()
                if child is None:
                    log(time.strftime("%T") + " CONNECT_FAIL")
                    time.sleep(10)
                    continue
                misses = 0
            try:
                if time.time() >= next_slow:
                    row(child, SLOW, " SLOW")
                    next_slow = time.time() + SLOW_S
                vals = row(child, FAST)
            except Exception as ex:
                log(time.strftime("%T") + " ERR " + str(ex))
                vals = {}
            cur = vals.get("DD69")
            amps = (int.from_bytes(cur[0:4], "big", signed=True) / 100
                    if cur else None)
            if amps is not None and abs(amps) >= 0.3:
                seen_charge = True
                quiet_since = None
                after_read = False
            elif seen_charge:
                quiet_since = quiet_since or time.time()
                if amps is not None and not after_read:
                    row(child, SLOW, " AFTER")
                    after_read = True
                if time.time() - quiet_since >= END_QUIET_S:
                    log(time.strftime("%T") + " charge over (quiet %.0f s)" %
                        (time.time() - quiet_since))
                    break
            if all(v is None for v in vals.values()):
                misses += 1
                if misses >= 3:  # dead link or sleeping car: start clean
                    child.close(force=True)
                    child = None
            else:
                misses = 0
            time.sleep(CADENCE_S)
        if child is not None:
            row(child, SLOW, " FINAL")
            p.normal_mode(child)
    finally:
        try:
            child and child.close(force=True)
        except Exception:
            pass
        clear_link()
        log("=== bmw charge log end %s" % time.strftime("%F %T"))


if __name__ == "__main__":
    sys.exit(main())
