# OBDb / Cadillac-LYRIQ contribution (staged)

Upstream-ready contribution of confirmed HV-battery signals for the
[OBDb/Cadillac-LYRIQ](https://github.com/OBDb/Cadillac-LYRIQ) repo, formatted to
their v3 schema.

## Contents

- `signalsets/v3/default.json` — 9 confirmed HV-battery signals (pack voltage,
  3 group voltages, 5 temperatures) in OBDb v3 format.
- `tests/test_cases/2025/commands/*.yaml` — real captured request/response pairs
  with expected decoded values (captured on a **2025** — the "Gen 1 Refresh" year
  per `generations.yaml`). Each signal's formula reproduces its test value
  exactly (self-verifying, like OBDb CI expects).
- `PR.md` — the pull-request description (what/how/provenance/what's excluded).

## To submit

1. Fork `OBDb/Cadillac-LYRIQ`.
2. Copy `signalsets/v3/default.json` and the `tests/test_cases/2025/commands/*.yaml`
   files into the fork (merge into their empty `default.json`).
3. Open a PR using `PR.md` as the description.

Everything here is original on-vehicle data, contributable under the repo's
CC BY-SA 4.0. See `../../docs/lyriq-did-map.md` and `../../docs/lyriq-re-log.md`
for the full reverse-engineering record behind these signals.
