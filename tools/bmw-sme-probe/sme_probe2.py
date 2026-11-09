"""SME probe, round 2: response timing + flow control (ISO-TP) on the Viecar.

Round 1 (2026-11-08) proved the SME answers at 07 with correct framing, but:
  * only the First Frame of multi-frame replies arrived (no flow control got
    through in CAF0 or ATCEA mode), and
  * the SME is slow: it sends 7F 22 78 (response pending) and the real answer
    lands after the adapter has already timed out.
  * the census used ATAR, which filters the wrong reply id for a 6F1 header.

This round: long adapter timeout, a set of flow-control experiments on the VIN
(known 20-byte reply), the i3 DIDs again, and a functional (DF) census with a
6xx mask. READ-ONLY: UDS 0x22 reads + J1979 mode 01 only. The only other frame
sent is an ISO-TP flow-control frame (07 30 00 00), which is transport-level,
not a service request.
"""
import re
import sys
import time

import pexpect

MAC = "00:1D:A5:00:00:01"
WRITE_HANDLE = "0x0016"
NOTIF = re.compile(r"Notification handle = 0x[0-9a-fA-F]+ value:\s*([0-9a-fA-F ]+)")
LOG = None
FC = "0730000000000000"  # flow control to SME 07: CTS, BS=0, STmin=0, padded


def out(*a):
    s = " ".join(str(x) for x in a)
    print(s, flush=True)
    LOG.write(s + "\n")
    LOG.flush()


def collect(child, timeout):
    buf = bytearray()
    end = time.time() + timeout
    while time.time() < end:
        try:
            child.expect(NOTIF, timeout=0.2)
            buf += bytes(int(h, 16) for h in child.match.group(1).split())
            if b">" in buf:
                break
        except pexpect.TIMEOUT:
            pass
        except pexpect.EOF:
            break
    return buf.decode("ascii", "replace").replace("\r", " | ").strip()


def send(child, c):
    child.sendline(f"char-write-cmd {WRITE_HANDLE} {(c + chr(13)).encode().hex()}")


def cmd(child, c, timeout=2.0, label=None):
    send(child, c)
    r = collect(child, timeout)
    out(f"  {label or c:<40} -> {r}")
    return r


def req(did):
    return f"0703{0x22:02X}{did}000000"


def setup(child, cmds):
    for c in cmds:
        cmd(child, c)


def connect(child):
    for _ in range(8):
        child.sendline("connect")
        if child.expect(["Connection successful", "connect error",
                         "Function not implemented", pexpect.TIMEOUT],
                        timeout=15) == 0:
            return True
        time.sleep(2)
    return False


def main():
    global LOG
    LOG = open(f"bmw_sme_probe2_{time.strftime('%Y%m%d_%H%M%S')}.txt", "w")
    child = pexpect.spawn(f"gatttool -b {MAC} -I", encoding="utf-8", timeout=20)
    if not connect(child):
        out("FAILED to connect to adapter")
        sys.exit(1)
    out("CONNECTED")

    out("\n== init ==")
    for c in ["ATZ", "ATE0", "ATL0", "ATS0", "ATH1", "ATSP6"]:
        cmd(child, c, 3.0 if c == "ATZ" else 1.5)
    cmd(child, "ATRV")
    r = cmd(child, "015B", 4.0, label="015B HV SOC (J1979)")
    if "41" not in r:
        out("!! bus asleep: car must be fully RUNNING. Aborting.")
        sys.exit(2)

    base = ["ATCAF0", "ATSH6F1", "ATCRA607", "ATAT0"]

    # ---- E1: CAF0 + custom FC, explicit ATCFC1, long timeout ----------------
    out("\n== E1: CAF0, FCSM1 (07 30 00 00), ATCFC1, ATSTFF ==")
    setup(child, base + ["ATSTFF", "ATCFC1", "ATFCSH6F1", "ATFCSD07300000",
                         "ATFCSM1"])
    cmd(child, req("F190"), 5.0, label="E1 22F190")

    # ---- E2: manual flow control: short timeout, send FC ourselves ---------
    out("\n== E2: manual FC (we send 07 30 00 00 right after the First Frame) ==")
    setup(child, ["ATFCSM0", "ATST19"])  # 25*4 = 100 ms adapter timeout
    for fc in [FC, "07300000"]:
        send(child, req("F190"))
        r1 = collect(child, 3.0)
        send(child, fc)
        r2 = collect(child, 3.0)
        out(f"  E2 22F190 + FC {fc:<18} -> {r1}  ||  FC -> {r2}")
        time.sleep(1.5)

    # ---- E3/E4: ATCEA mode with custom FC data ------------------------------
    for name, fcsd in [("E3", "300000"), ("E4", "07300000")]:
        out(f"\n== {name}: CAF1 + ATCEA07 + FCSM1 FCSD {fcsd} ==")
        setup(child, ["ATCAF1", "ATCEA07", "ATSH6F1", "ATCRA607", "ATSTFF",
                      "ATFCSH6F1", f"ATFCSD{fcsd}", "ATFCSM1"])
        cmd(child, "22F190", 5.0, label=f"{name} 22F190")
    setup(child, ["ATCEA", "ATFCSM0"])

    # ---- SME DIDs with long timeout (catch 7F 22 78 then the answer) --------
    out("\n== SME DIDs, CAF0, ATSTFF (pending-tolerant), FF-only ok ==")
    setup(child, base + ["ATSTFF", "ATFCSH6F1", "ATFCSD07300000", "ATFCSM1"])
    for did in ["DDBC", "6335", "DD68", "DD69", "DDC0", "DFA0"]:
        cmd(child, req(did), 6.0, label=f"22{did}")
        time.sleep(1.0)  # let a slow SME finish before the next request

    # ---- Functional census: DF = all ECUs, accept any 6xx reply -------------
    out("\n== census: functional DF 22F190, receive mask 6xx ==")
    setup(child, ["ATCAF0", "ATSH6F1", "ATCRA", "ATCF600", "ATCM700",
                  "ATSTFF"])
    r = cmd(child, "DF0322F190000000", 8.0, label="DF 22F190")
    ids = sorted(set(re.findall(r"\b(6[0-9A-F]{2})F1", r.replace(" | ", " "))))
    out(f"census: reply ids = {ids}  (ECU addr = id - 0x600)")

    setup(child, ["ATCRA", "ATCAF1", "ATFCSM0", "ATAT1", "ATST32"])
    out("\ndone")
    child.sendline("disconnect")
    child.sendline("exit")


if __name__ == "__main__":
    main()
