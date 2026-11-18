"""BMW 330e (F30 PHEV) SME probe — the canonical one. READ-ONLY.

Uses the adapter recipe proven on the car on 2026-11-08 with the Viecar
ELM327 v2.2 clone (see docs/bmw-330e-sme.md):

    ATCAF1  ATCEA07  ATFCSH6F1  ATFCSD07300000  ATFCSM1  ATAT0  ATSTFF

  * ATCEA07 makes the adapter put the SME address byte BEFORE the ISO-TP PCI.
  * The clone's own flow control omits the address, so a custom FC frame
    `07 30 00 00` is required, or only the First Frame of a reply arrives.
  * The SME often answers `7F 22 78` (response pending) first, so timing is
    maxed and pending frames are skipped when decoding.

Only UDS 0x22 reads and J1979 mode 01 are sent (plus the ISO-TP flow-control
frame the adapter sends). Nothing is written, coded or cleared.

Run ON THE PI, car fully RUNNING (READY):
    python3 sme_probe.py                       # read + decode the known DIDs
    python3 sme_probe.py --census              # also list ECUs behind the gateway
    python3 sme_probe.py --sweep DD00 DDFF     # also sweep an SME DID range
    python3 sme_probe.py --target 12 --sweep 4000 40FF   # sweep another ECU
    python3 sme_probe.py --read DFAC DF67 DF62           # raw-read chosen DIDs
    python3 sme_probe.py --target 3A --read DEA6 DEA7    # EME motor temps/rpm/torque
    python3 sme_probe.py --no-gate             # charging: J1979 silent, try SME
Output: printed and written to bmw_sme_<timestamp>.txt

(sme_probe2.py / sme_probe3.py are the 2026-11-08 experiments that found the
recipe; kept for the record.)
"""
import argparse
import re
import sys
import time

import pexpect

MAC = "00:1D:A5:00:00:01"  # Viecar BT4.0
WRITE_HANDLE = "0x0016"
NOTIF = re.compile(r"Notification handle = 0x[0-9a-fA-F]+ value:\s*([0-9a-fA-F ]+)")
LOG = None


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
    return buf.decode("ascii", "replace")


def cmd(child, c, timeout=2.0, label=None, quiet=False):
    child.sendline(f"char-write-cmd {WRITE_HANDLE} {(c + chr(13)).encode().hex()}")
    raw = collect(child, timeout)
    if not quiet:
        out(f"  {label or c:<26} -> {raw.strip().replace(chr(13), ' | ')}")
    return raw


def ext_mode(child, target):
    for c in ["ATCAF1", f"ATCEA{target:02X}", "ATSH6F1", f"ATCRA{0x600 + target:03X}",
              "ATAT0", "ATSTFF", "ATFCSH6F1", f"ATFCSD{target:02X}300000",
              "ATFCSM1"]:
        cmd(child, c, quiet=True)


def normal_mode(child):
    for c in ["ATCEA", "ATFCSM0", "ATCRA", "ATAT1", "ATST32", "ATSH7DF"]:
        cmd(child, c, quiet=True)


def uds_message(raw):
    """Reassemble one extended-addressing reply (lines `6xx F1 <PCI> ...`).
    Returns the UDS message bytes, or None. Skips 7F xx 78 pending frames."""
    frames = []
    for line in raw.replace(">", "").split("\r"):
        h = re.sub(r"[^0-9A-Fa-f]", "", line)
        if len(h) < 7 or len(h) % 2 == 0:  # 3-nibble id + even data
            continue
        data = bytes.fromhex(h[3:])[1:]  # drop the F1 address byte
        if len(data) >= 4 and data[0] == 0x03 and data[1] == 0x7F and data[3] == 0x78:
            continue
        frames.append(data)
    if not frames:
        return None
    f0 = frames[0]
    if f0[0] >> 4 == 0:
        return f0[1:1 + f0[0]]
    if f0[0] >> 4 != 1:
        return None
    total = ((f0[0] & 0x0F) << 8) | f0[1]
    buf = bytearray(f0[2:])
    for f in frames[1:]:
        if f[0] >> 4 == 2:
            buf += f[1:]
    return bytes(buf[:total]) if len(buf) >= total else None


def u16(d, i):
    return int.from_bytes(d[i:i + 2], "big")


def s16(d, i):
    return int.from_bytes(d[i:i + 2], "big", signed=True)


def decode(did, d):
    """Human-readable decode of the DIDs mapped in signalsets v02."""
    if did == "F190":
        return "VIN " + d.decode("ascii", "replace")
    if did == "DDBC":
        return (f"SOC {u16(d, 0) / 10:.1f} %  window {u16(d, 4) / 10:.1f}"
                f"..{u16(d, 2) / 10:.1f} %")
    if did == "6335":
        return f"SOH {d[3]} %  (i3 layout, not ground-truthed)"
    if did == "DD69":
        return f"current {int.from_bytes(d[0:4], 'big', signed=True) / 100:.2f} A"
    if did == "DDC0":
        return (f"cell temp min/max/avg {s16(d, 0) / 100:.2f} / "
                f"{s16(d, 2) / 100:.2f} / {s16(d, 4) / 100:.2f} C")
    if did == "DFA0" and len(d) >= 36:
        return (f"cell V {u16(d, 6) / 1e4:.4f}/{u16(d, 8) / 1e4:.4f}/"
                f"{u16(d, 10) / 1e4:.4f}  V2 {u16(d, 30) / 1e4:.4f}/"
                f"{u16(d, 32) / 1e4:.4f}/{u16(d, 34) / 1e4:.4f}  cell SoC "
                f"{u16(d, 24) / 100:.2f}/{u16(d, 26) / 100:.2f}/"
                f"{u16(d, 28) / 100:.2f} %  (min/max/avg)")
    # EME (target 3A) motor data, BMW i3 layout: unconfirmed on the 330e.
    if did == "DEA6" and len(d) >= 4:
        return (f"motor temp 1/2 {s16(d, 0) / 64:.1f} / {s16(d, 2) / 64:.1f} C"
                f"  (i3 layout, unconfirmed)")
    if did == "DEA7" and len(d) >= 6:
        return (f"motor {u16(d, 0) / 2 - 5000:.0f} rpm  torque actual/target "
                f"{s16(d, 2) / 2:.1f} / {s16(d, 4) / 2:.1f} Nm"
                f"  (i3 layout, unconfirmed)")
    return ""


def read_did(child, did, label=None):
    raw = cmd(child, f"22{did}", 8.0, quiet=True)
    msg = uds_message(raw)
    if msg is None:
        out(f"  22{did:<6} -> no reply   [{raw.strip().replace(chr(13), ' | ')}]")
        return None
    if msg[0] == 0x7F:
        out(f"  22{did:<6} -> negative response NRC 0x{msg[2]:02X}")
        return None
    data = msg[3:]
    out(f"  22{did:<6} -> {data.hex(' ')}")
    text = decode(did, data)
    if text:
        out(f"  {'':8}    = {text}")
    return data


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
    ap = argparse.ArgumentParser()
    ap.add_argument("--census", action="store_true",
                    help="ask targets 00-7F for VIN to list ECUs behind the gateway")
    ap.add_argument("--sweep", nargs=2, metavar=("START", "END"),
                    help="sweep DIDs START..END (hex), e.g. DD00 DDFF")
    ap.add_argument("--target", default="07",
                    help="ECU address (hex) for --sweep; default 07 = SME")
    ap.add_argument("--read", nargs="+", metavar="DID",
                    help="raw-read these DIDs on --target (e.g. counters)")
    ap.add_argument("--fast", action="store_true",
                    help="short timeout for --sweep (fast ECUs like the DME; "
                         "the SME needs the default long one)")
    ap.add_argument("--no-gate", action="store_true",
                    help="keep going when J1979 is silent (engine ECU asleep, "
                         "e.g. plugged in and charging) and try the SME anyway")
    args = ap.parse_args()

    LOG = open(f"bmw_sme_{time.strftime('%Y%m%d_%H%M%S')}.txt", "w")
    child = pexpect.spawn(f"gatttool -b {MAC} -I", encoding="utf-8", timeout=20)
    if not connect(child):
        out("FAILED to connect to adapter")
        sys.exit(1)
    out("CONNECTED")

    for c in ["ATZ", "ATE0", "ATL0", "ATS0", "ATH1", "ATSP6"]:
        cmd(child, c, 3.0 if c == "ATZ" else 1.5, quiet=True)
    cmd(child, "ATRV", label="battery (needs ~14 V)")
    r = cmd(child, "015B", 4.0, label="015B J1979 HV SOC")
    m = re.search(r"415B([0-9A-F]{2})", r.replace(" ", ""))
    if m:
        out(f"  {'':26}    = {int(m.group(1), 16) * 100 / 255:.1f} %")
    elif args.no_gate:
        out("!! no J1979 reply (engine ECU asleep); --no-gate: trying the SME")
    else:
        out("!! no J1979 reply: bus asleep. The car must be fully RUNNING.")
        sys.exit(2)

    out("\n== SME (07) ==")
    ext_mode(child, 0x07)
    for did in ["F190", "DDBC", "6335", "DD69", "DDC0", "DFA0"]:
        read_did(child, did)
        time.sleep(0.5)

    if args.read:
        target = int(args.target, 16)
        out(f"\n== ECU {target:02X} read: {' '.join(args.read)} ==")
        ext_mode(child, target)
        for did in args.read:
            data = read_did(child, did.upper())
            if data is not None and len(data) % 4 == 0:
                out(f"  {'':8}    = u32 " + " ".join(
                    str(int.from_bytes(data[i:i + 4], "big"))
                    for i in range(0, len(data), 4)))

    if args.sweep:
        lo, hi = int(args.sweep[0], 16), int(args.sweep[1], 16)
        target = int(args.target, 16)
        out(f"\n== ECU {target:02X} DID sweep {lo:04X}..{hi:04X} (misses not shown) ==")
        ext_mode(child, target)
        if args.fast:
            cmd(child, "ATST40", quiet=True)  # ~256 ms instead of ~1 s
        for did in range(lo, hi + 1):
            raw = cmd(child, f"22{did:04X}", 3.0 if args.fast else 8.0,
                      quiet=True)
            msg = uds_message(raw)
            if msg and msg[0] == 0x7F and msg[2] == 0x78:
                out(f"  22{did:04X} -> response pending (reply lost in --fast)")
            elif msg and msg[0] == 0x62:
                out(f"  22{did:04X} -> {msg[3:].hex(' ')}")
            elif msg and msg[0] == 0x7F and msg[2] != 0x31:
                out(f"  22{did:04X} -> NRC 0x{msg[2]:02X}")

    if args.census:
        out("\n== census: 22F190 to each target 00-7F ==")
        found = []
        for addr in range(0x00, 0x80):
            ext_mode(child, addr)
            cmd(child, "ATST40", quiet=True)  # ~256 ms: enough for a reply
            raw = cmd(child, "22F190", 2.0, quiet=True)
            if f"{0x600 + addr:03X}" in raw.replace(" ", ""):
                found.append(f"{addr:02X}")
                out(f"  target {addr:02X} answers")
        out(f"census: {found}")

    normal_mode(child)
    out("\ndone")
    child.sendline("disconnect")
    child.sendline("exit")


if __name__ == "__main__":
    main()
