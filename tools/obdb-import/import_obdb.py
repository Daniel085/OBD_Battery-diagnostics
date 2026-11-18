#!/usr/bin/env python3
"""Turn OBDb signal sets (https://github.com/OBDb, CC BY-SA 4.0) into this
app's signal sets, and OBDb's captured test replies into replay fixtures.

    python3 tools/obdb-import/import_obdb.py tools/obdb-import/<vehicle>.map.json \
        --repo OBDb/Ford-F-150-Lightning=/path/to/checkout [--repo ...]

A map file picks the signals worth polling for battery diagnostics, gives the
ones the app's logic looks for their canonical ids (HVBAT_SOC, HVBAT_CURRENT,
...), a group, and optionally a clearer name. Everything else (request,
bit layout, scaling) is copied from OBDb unchanged, except:

  * units are renamed to the app's (kilometers -> km, ampereHours -> amp_hours)
  * fahrenheit signals are rescaled to celsius (the app converts for display)
  * `offon` signals become named values (0 Off, 1 On); other named values
    use OBDb's description ("Not ready") rather than its token (NOT_READY)
  * a command's OBDb `freq` (seconds between reads) is kept only above 1 s
  * an entry marked `"unconfirmed": true` gets a `?` on its unit and
    "(unconfirmed)" on its name: OBDb has the signal for a sibling model,
    nobody has confirmed it on this one.

Outputs (paths from the map file): the signal set JSON and, when the map
names `fixtureYears`, a fixtures JSON with OBDb's real replies and the values
OBDb expects from them, which test/obdb_import_test.dart replays.
Standard library only; the OBDb files are read as data.
"""
import argparse
import json
import os
import re
import sys

UNITS = {
    "kilometers": "km", "kilometersPerHour": "km/h", "ampereHours": "amp_hours",
    "kilowattHours": "kWh", "kilowatts": "kW", "newtonMeters": "Nm",
    "hertz": "Hz", "milliamps": "mA", "seconds": "s", "kilopascal": "kPa",
    "gravity": "g", "scalar": None, "unknown": None, "offon": None,
    # unchanged: percent volts amps celsius hours rpm psi degrees kiloohms
}
OFF_ON = {"0": {"value": "Off"}, "1": {"value": "On"}}


def convert_fmt(fmt):
    """OBDb fmt -> app fmt. Returns (fmt, value_converter)."""
    out = {k: v for k, v in fmt.items() if k != "unit"}
    unit = fmt.get("unit")
    conv = lambda v: v  # noqa: E731
    if unit == "fahrenheit":
        # F = raw*mul/div + add  ->  C = (F - 32) * 5/9
        out["mul"] = fmt.get("mul", 1) * 5
        out["div"] = fmt.get("div", 1) * 9
        out["add"] = round((fmt.get("add", 0) - 32) * 5 / 9, 6)
        for k in ("min", "max", "nullmin", "nullmax"):
            if k in fmt:
                out[k] = round((fmt[k] - 32) * 5 / 9, 3)
        unit = "celsius"
        conv = lambda v: (v - 32) * 5 / 9  # noqa: E731
    elif unit == "offon":
        out.setdefault("map", OFF_ON)
        conv = lambda v: {"OFF": "Off", "ON": "On", 0: "Off", 1: "On", False: "Off", True: "On"}.get(v.upper() if isinstance(v, str) else v, v)  # noqa: E731,E501
    if "map" in out and unit != "offon":
        # OBDb names a value twice: a token (NOT_READY) and a description
        # (Not ready). The app shows one name, so use the readable one.
        tokens = {v["value"]: v.get("description", v["value"])
                  for v in fmt["map"].values() if isinstance(v, dict)}
        out["map"] = {k: {"value": (v.get("description", v["value"])
                                    if isinstance(v, dict) else v)}
                      for k, v in fmt["map"].items()}
        conv = lambda v: tokens.get(v, v)  # noqa: E731
    unit = UNITS.get(unit, unit)
    if unit is not None:
        out["unit"] = unit
    return out, conv


def command_key(c):
    service, payload = next(iter(c["cmd"].items()))
    return (c.get("hdr"), c.get("rax"), service, payload)


def covers_year(c, year):
    f = c.get("filter")
    if not f or year is None:
        return True
    if "years" in f and year in f["years"]:
        return True
    lo, hi = f.get("from"), f.get("to")
    if lo is None and hi is None:
        return "years" not in f
    return (lo is None or year >= lo) and (hi is None or year <= hi)


# --- the small subset of YAML that OBDb's test cases use -------------------
def scalar(text):
    t = text.strip()
    if len(t) >= 2 and t[0] == t[-1] and t[0] in "'\"":
        return t[1:-1]
    if t in ("null", "~"):
        return None  # OBDb: this reply decodes to "no value"
    if t in ("true", "false"):
        return t == "true"
    try:
        return int(t)
    except ValueError:
        try:
            return float(t)
        except ValueError:
            return t


def parse_test_cases(path):
    cases, cur, block = [], None, None
    for raw in open(path, encoding="utf-8"):
        line = raw.rstrip("\n")
        if block is not None:
            if line.startswith(" " * block[0]) and line.strip():
                block[1].append(line.strip())
                continue
            cur["response"] = "\n".join(block[1])
            block = None
        m = re.match(r"^- expected_values:\s*(\{\})?\s*$", line)
        if m:
            cur = {"expected": {}, "response": None}
            cases.append(cur)
            continue
        if cur is None:
            continue
        m = re.match(r"^(\s+)response:\s*(.*)$", line)
        if m:
            if m.group(2).startswith("|"):
                block = (len(m.group(1)) + 2, [])
            else:
                cur["response"] = str(scalar(m.group(2)))
            continue
        m = re.match(r"^\s{4,}([A-Za-z0-9_]+):\s*(.+)$", line)
        if m and cur["response"] is None:
            cur["expected"][m.group(1)] = scalar(m.group(2))
    if block is not None:
        cur["response"] = "\n".join(block[1])
    return [c for c in cases if c["response"]]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("map")
    ap.add_argument("--repo", action="append", default=[],
                    help="OBDb/<name>=<checkout dir>")
    args = ap.parse_args()
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    mp = json.load(open(args.map, encoding="utf-8"))
    repos = dict(r.split("=", 1) for r in args.repo)
    year = mp.get("modelYear")

    sources = {}
    for name, info in mp["sources"].items():
        if name not in repos:
            sys.exit(f"missing --repo {name}=<dir>")
        data = json.load(open(os.path.join(repos[name], "signalsets/v3/default.json"),
                              encoding="utf-8"))
        index = {}
        for c in data["commands"]:
            for s in c["signals"]:
                index[s["id"]] = (c, s)
        sources[name] = index

    commands, by_key, id_map, converters = [], {}, {}, {}
    for e in mp["signals"]:
        repo = e.get("from", mp["defaultSource"])
        if e["obdb"] not in sources[repo]:
            sys.exit(f"{repo} has no signal {e['obdb']}")
        c, s = sources[repo][e["obdb"]]
        if not covers_year(c, year) and not e.get("unconfirmed"):
            sys.exit(f"{e['obdb']} is filtered out for model year {year}")
        key = command_key(c)
        cmd = by_key.get(key)
        if cmd is None:
            cmd = {"_source": f"{repo}: "}
            for k in ("hdr", "rax"):
                if c.get(k):
                    cmd[k] = c[k]
            if c.get("fcm1"):
                cmd["fcm1"] = True
            if c.get("freq", 0) > 1:
                cmd["freq"] = c["freq"]
            cmd["cmd"] = c["cmd"]
            cmd["signals"] = []
            cmd["_ids"] = []
            by_key[key] = cmd
            commands.append(cmd)
        fmt, conv = convert_fmt(s["fmt"])
        new_id = e.get("id", e["obdb"])
        name = e.get("name", s["name"])
        if e.get("unconfirmed"):
            name += " (unconfirmed)"
            if "unit" in fmt:
                fmt["unit"] += "?"
            cmd["_unconfirmed"] = (
                f"Not confirmed on this vehicle. Definition taken from {repo} "
                "(a sibling Ford with the same battery controller identifiers).")
        if "fmt" in e:
            # A map-file override of the scaling (e.g. days -> hours) applies
            # to OBDb's expected test values too.
            k = (e["fmt"].get("mul", fmt.get("mul", 1)) / fmt.get("mul", 1)
                 * fmt.get("div", 1) / e["fmt"].get("div", fmt.get("div", 1)))
            base = conv
            conv = (lambda v, base=base, k=k:  # noqa: E731
                    base(v) * k if isinstance(base(v), (int, float)) else base(v))
            fmt.update(e["fmt"])
        cmd["signals"].append({"id": new_id, "name": name, "group": e["group"], "fmt": fmt})
        cmd["_ids"].append(e["obdb"])
        id_map[(repo, e["obdb"])] = new_id
        converters[(repo, e["obdb"])] = conv
    for cmd in commands:
        cmd["_source"] += ", ".join(cmd.pop("_ids"))

    out = {
        "$schema": "../signalset.schema.json",
        "vehicle": mp["vehicle"],
        "description": mp["description"],
        "provenance": {
            "derivedFrom": "; ".join(
                f"{n} @ {i['commit'][:10]} ({i['date']}), signalsets/v3/default.json"
                for n, i in mp["sources"].items()) + " (CC BY-SA 4.0)",
            "confidence": mp["confidence"],
            "license": "CC BY-SA 4.0",
        },
        "protocol": mp["protocol"],
        "commands": commands,
    }
    if "pack" in mp:
        out["pack"] = mp["pack"]
    path = os.path.join(root, mp["output"])
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2, ensure_ascii=False)
        f.write("\n")
    nsig = sum(len(c["signals"]) for c in commands)
    print(f"{mp['output']}: {len(commands)} commands, {nsig} signals")

    if not mp.get("fixtureYears"):
        return
    repo = mp["defaultSource"]
    cases = []
    for (hdr, rax, service, payload), cmd in by_key.items():
        seen = set()
        for y in mp["fixtureYears"]:
            d = os.path.join(repos[repo], "tests/test_cases", str(y), "commands")
            if not os.path.isdir(d):
                continue
            prefix = f"{hdr}.{rax}.{service}{payload}" if rax else f"{hdr}.{service}{payload}"
            for fn in sorted(os.listdir(d)):
                if not (fn == prefix + ".yaml" or fn.startswith(prefix + "|")):
                    continue
                for tc in parse_test_cases(os.path.join(d, fn)):
                    # With the receive filter set, the adapter passes only the
                    # addressed ECU's frames.
                    lines = [ln for ln in tc["response"].split("\n")
                             if not rax or ln.upper().startswith(rax.upper())]
                    expected = {
                        id_map[(repo, k)]: converters[(repo, k)](v)
                        for k, v in tc["expected"].items() if (repo, k) in id_map}
                    resp = "\r".join(lines)
                    if not lines or not expected or resp in seen or len(seen) >= 4:
                        continue
                    seen.add(resp)
                    cases.append({"year": y, "hdr": hdr, "rax": rax,
                                  "request": service + payload,
                                  "response": resp, "expected": expected})
    fx = {
        "vehicle": mp["vehicle"],
        "signalSet": mp["output"],
        "source": f"{repo} @ {mp['sources'][repo]['commit'][:10]}, tests/test_cases "
                  "(replies captured by OBDb contributors; CC BY-SA 4.0)",
        "cases": cases,
    }
    fpath = os.path.join(root, mp["fixtures"])
    os.makedirs(os.path.dirname(fpath), exist_ok=True)
    with open(fpath, "w", encoding="utf-8") as f:
        json.dump(fx, f, indent=1, ensure_ascii=False)
        f.write("\n")
    covered = len({(c["hdr"], c["request"]) for c in cases})
    print(f"{mp['fixtures']}: {len(cases)} replies covering {covered} of {len(commands)} commands")


if __name__ == "__main__":
    main()
