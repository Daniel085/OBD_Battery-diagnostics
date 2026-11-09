"""SME probe, round 3: full multi-frame reads with the recipe proven in round 2
(E4): ATCAF1 + ATCEA07 + custom flow control 07 30 00 00, long timeout for the
SME's 7F 22 78 response-pending. READ-ONLY (UDS 0x22 only)."""
import sys
import time

import pexpect

import sme_probe2 as p2

DIDS = ["F190", "DDBC", "6335", "DD69", "DDC0", "DFA0"]


def main():
    p2.LOG = open(f"bmw_sme_probe3_{time.strftime('%Y%m%d_%H%M%S')}.txt", "w")
    child = pexpect.spawn(f"gatttool -b {p2.MAC} -I", encoding="utf-8", timeout=20)
    if not p2.connect(child):
        p2.out("FAILED to connect")
        sys.exit(1)
    for c in ["ATZ", "ATE0", "ATL0", "ATS0", "ATH1", "ATSP6"]:
        p2.cmd(child, c, 3.0 if c == "ATZ" else 1.5)
    p2.cmd(child, "ATRV")
    p2.setup(child, ["ATCAF1", "ATCEA07", "ATSH6F1", "ATCRA607", "ATAT0",
                     "ATSTFF", "ATFCSH6F1", "ATFCSD07300000", "ATFCSM1"])
    for rnd in (1, 2):
        p2.out(f"\n== round {rnd} ==")
        for did in DIDS:
            p2.cmd(child, f"22{did}", 8.0, label=f"22{did}")
            time.sleep(0.8)
    p2.setup(child, ["ATCEA", "ATFCSM0", "ATCRA", "ATAT1", "ATST32"])
    p2.out("done")
    child.sendline("disconnect")
    child.sendline("exit")


if __name__ == "__main__":
    main()
