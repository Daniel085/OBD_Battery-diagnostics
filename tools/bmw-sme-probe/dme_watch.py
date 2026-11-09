"""Watch DME (12) candidate 12 V battery DIDs next to J1979 0142 (module
voltage) to see which fields track the 12 V system. READ-ONLY (0x22 + mode 01).
    python3 dme_watch.py [DID ...]   default: 40E6 40E7 40E8 4021
    ROUNDS=3 python3 dme_watch.py ...  (default 6 rounds)
Prints, per DID, whether its bytes changed across rounds (live) or not.
"""
import os
import re
import sys
import time

import pexpect

import sme_probe as p

DIDS = sys.argv[1:] or ["40E6", "40E7", "40E8", "4021"]


def main():
    p.LOG = open(f"dme_watch_{time.strftime('%Y%m%d_%H%M%S')}.txt", "w")
    child = pexpect.spawn(f"gatttool -b {p.MAC} -I", encoding="utf-8", timeout=20)
    if not p.connect(child):
        p.out("FAILED to connect")
        sys.exit(1)
    for c in ["ATZ", "ATE0", "ATL0", "ATS0", "ATH1", "ATSP6"]:
        p.cmd(child, c, 3.0 if c == "ATZ" else 1.5, quiet=True)
    seen = {d: set() for d in DIDS}
    rounds = int(os.environ.get("ROUNDS", "6"))
    for i in range(rounds):
        p.normal_mode(child)
        rv = p.cmd(child, "ATRV", quiet=True).strip().split()[0]
        r = p.cmd(child, "0142", 3.0, quiet=True).replace(" ", "")
        m = re.search(r"4142([0-9A-F]{4})", r)
        v42 = f"{int(m.group(1), 16) / 1000:.3f} V" if m else "?"
        row = [f"#{i} ATRV {rv} 0142 {v42}"]
        p.ext_mode(child, 0x12)
        p.cmd(child, "ATST40", quiet=True)
        for did in DIDS:
            msg = p.uds_message(p.cmd(child, f"22{did}", 3.0, quiet=True))
            data = msg[3:].hex(' ') if msg and msg[0] == 0x62 else '-'
            seen[did].add(data)
            row.append(f"{did}: {data}")
        p.out("  " + "  |  ".join(row))
        time.sleep(2)
    p.out("\nLIVE (changed): " + " ".join(d for d in DIDS if len(seen[d]) > 1))
    p.out("static:         " + " ".join(d for d in DIDS if len(seen[d]) == 1))
    p.normal_mode(child)
    child.sendline("disconnect")
    child.sendline("exit")


if __name__ == "__main__":
    main()
