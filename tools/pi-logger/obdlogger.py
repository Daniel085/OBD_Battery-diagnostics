"""OBD register logger, supervisor-driven.

One "shift": connects to the Viecar, reads a fixed DID set on a fixed cadence,
appends timestamped rows to a data file, and returns when its short shift
window elapses OR a stop file appears OR it hits an unrecoverable error. The
supervisor (logsup.sh) relaunches it, so a dropped BLE link / sleeping car
just ends a shift instead of killing logging for the session.

Config via env:
  OBD_LOGFILE   data file to append to        (required)
  OBD_SHIFT_S   shift length in seconds        (default 900 = 15 min)
  OBD_CADENCE_S seconds between sample bursts  (default 30)
  OBD_STOPFILE  touch to stop cleanly          (default ~/obdbridge/logger.stop)
  OBD_PROFILE   "charge" (default) or "drive"  selects the DID set
"""
import os, re, time, pexpect, subprocess

MAC = "00:1D:A5:00:00:01"; WH = "0x0016"
N = re.compile(r"Notification handle = 0x[0-9a-fA-F]+ value:\s*([0-9a-fA-F ]+)")

LOGFILE = os.environ["OBD_LOGFILE"]
SHIFT_S = float(os.environ.get("OBD_SHIFT_S", "900"))
CADENCE_S = float(os.environ.get("OBD_CADENCE_S", "30"))
STOPFILE = os.environ.get("OBD_STOPFILE",
                          os.path.expanduser("~/obdbridge/logger.stop"))
PROFILE = os.environ.get("OBD_PROFILE", "charge")

# Charge profile: pack I/V, charge record, SOH regs, temps. Slow cadence OK.
CHARGE = [("18DA17F1", "18DAF117", ["2414", "2429"]),
          ("18DA40F1", "18DAF140", ["441F", "4149", "44C0", "44C1", "416C",
                                     "4127", "40E5", "44C5", "406E",
                                     "443C", "4441", "451D"])]
# Drive profile: focus on fast-changing signals — pack current (power),
# nominal V, temps, module V, plus the dynamics ECU (speed/accel/steering).
# Fewer DIDs per burst = higher effective rate for the power trace.
DRIVE = [("18DA17F1", "18DAF117", ["2414", "2429"]),
         ("18DA40F1", "18DAF140", ["40E5", "434F", "416C"]),
         ("18DA28F1", "18DAF128", ["4A7A", "4C2F", "4C30", "4C2D"])]
GROUPS = DRIVE if PROFILE == "drive" else CHARGE


def coll(c, s):
    hb = []; e = time.time() + s
    while time.time() < e:
        try:
            c.expect(N, timeout=0.13); hb += c.match.group(1).split()
        except pexpect.TIMEOUT:
            pass
        except pexpect.EOF:
            break
    return "".join(chr(int(h, 16)) for h in hb if 32 <= int(h, 16) < 127)


def cmd(c, x, w):
    c.sendline("char-write-cmd " + WH + " " + (x + "\r").encode().hex())
    return coll(c, w)


def clear_link():
    # Best-effort BLE link reset between connects. bluetoothctl can hang on
    # this BlueZ, so cap it hard and SWALLOW EVERYTHING — a failed disconnect
    # must never crash the shift (that would make the supervisor spin-relaunch).
    try:
        subprocess.run(["bluetoothctl", "--timeout", "1", "disconnect", MAC],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=6, check=False)
    except Exception:
        pass


LOG = open(LOGFILE, "a")


def log(s):
    LOG.write(s + "\n"); LOG.flush(); print(s, flush=True)


def stopping():
    return os.path.exists(STOPFILE)


END = time.time() + SHIFT_S
log("=== shift start %s profile=%s cadence=%.0fs" %
    (time.strftime("%F %T"), PROFILE, CADENCE_S))
while time.time() < END and not stopping():
    clear_link()
    c = None
    try:
        c = pexpect.spawn("gatttool -b " + MAC + " -t public -I",
                          encoding="utf-8", timeout=15, codec_errors="replace")
        c.expect(r"\[.*\]"); ok = False
        for _ in range(3):
            c.sendline("connect")
            if c.expect(["Connection successful", "connect error",
                         "Function not implemented", pexpect.TIMEOUT],
                        timeout=10) == 0:
                ok = True; break
            time.sleep(2)
        if not ok:
            log(time.strftime("%T") + " CONNECT_FAIL")
        else:
            for s in ["ATZ", "ATE0", "ATH1", "ATS0", "ATSP7", "ATCAF1"]:
                cmd(c, s, 0.45)
            # Keep reading bursts on this one link until the shift/cadence
            # says otherwise — reconnecting every burst was most of the old
            # overhead. A link drop throws, ends the shift, supervisor relaunches.
            while time.time() < END and not stopping():
                row = []
                for hdr, rax, dids in GROUPS:
                    cmd(c, "ATSH " + hdr, 0.3)
                    cmd(c, "ATCRA " + rax, 0.3)
                    cmd(c, "ATFCSH " + hdr, 0.3)
                    ecu = hdr[4:6]
                    for d in dids:
                        w = 1.2 if d in ("441F", "44C5") else 0.5
                        tag = (ecu + "." + d) if hdr != "18DA40F1" else d
                        row.append(tag + "=" +
                                   re.sub(r"[^0-9A-Fa-f]", "", cmd(c, "22" + d, w)))
                log(time.strftime("%T") + " " + " ".join(row))
                time.sleep(CADENCE_S)
    except Exception as ex:
        log(time.strftime("%T") + " ERR " + str(ex))
    finally:
        try:
            c and c.close(force=True)
        except Exception:
            pass
    if not stopping():
        time.sleep(3)
log("=== shift end %s" % time.strftime("%F %T"))
