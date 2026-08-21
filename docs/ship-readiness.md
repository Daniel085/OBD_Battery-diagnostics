# Ship readiness — gap list for a public TestFlight / App Store release

Goal (2026-08-21): validate demand as a prosumer "battery insight for GM
Ultium EVs" app. Strategy context: the wedge is Ultium-specific battery
data + the coulomb-counting capacity test; growth loop is the in-app
scanner crowdsourcing signal confirmation across Ultium models
(Blazer/Equinox/Silverado EV). Phase-2/3 (certificates, dealer B2B) only
after demand signal.

## Done (this pass)

- [x] Home screen no longer undersells the product (stale "Lyriq HV BMS not
      reverse-engineered" copy replaced with confirmed-signal reality).
- [x] iOS no longer prompts for location (Android-only BLE-scan requirement).
- [x] Connect/poll failures are human-first: short plain-language message,
      exception + adapter GATT table behind a collapsed "Technical details".
- [x] RE tools (terminal, DID scanner) moved behind an Advanced overflow menu
      on the dashboard; capacity test + health report are the primary actions.
- [x] Lyriq demo mode: `SimulatedLyriqSource` answers the entire confirmed
      signal set (29-bit, values from real captures) and simulates a steady
      9 kW charge so the capacity test demos end-to-end without a car.
      CI-tested to cover every signal in the set.

## Code gaps (next passes)

- [ ] **Dashboard hierarchy**: pack current / SOH / temps as hero cards;
      odometer & dynamics demoted. The flat 165px-card grid treats steering
      angle and pack current as equals.
- [ ] **First-run onboarding**: 2-3 screens — what the app does, adapter
      guidance (recommend OBDLink CX; warn about clones), privacy one-liner.
- [ ] **Adapter compatibility UX**: detect clone quirks at connect (we already
      auto-diagnose GATT layouts) and surface "this adapter may not reach the
      battery bus — OBDLink CX recommended" proactively rather than silent
      NO DATA.
- [ ] **Capacity-test UX polish**: charge-start reminder notification
      (connect at plug-in / at cutoff), result history (drift DB — dependency
      already present), share result as image/PDF.
- [ ] **Ultium portability**: signal-set skeletons for Blazer EV / Equinox EV
      (same DIDs hypothesized, `_unconfirmed_` markers) + a guided
      "confirm my car" flow around the scanner that produces a shareable
      capture bundle for validation → the crowdsourcing engine.
- [ ] **Error/session telemetry**: opt-in anonymous diagnostics (which
      adapter, which vehicle, which signals answered) — the data that tells us
      which models/adapters to support next. Needs privacy policy first.
- [ ] App icon (current is the Flutter default).
- [ ] Settings screen: units (°F option exists only in the HTML dashboard),
      poll interval, advanced-mode toggle.

## Non-code gaps (Daniel)

- [ ] **Name/brand** — "OBD Battery Diagnostics" is a description, not a
      product. Pick a name before TestFlight (bundle id + display name follow).
- [ ] **Privacy policy** — App Store requirement, needed before any telemetry.
      One page, host anywhere stable.
- [ ] **Crash reporting account** — Sentry or Firebase Crashlytics (free tier
      fine). Code wiring is trivial once the account/DSN exists.
- [ ] **App Store assets** — screenshots (demo mode makes this easy),
      description copy, keywords ("Lyriq", "Ultium", "EV battery health").
- [ ] **Demand test** — LyriqForum / r/CadillacLyriq / GM-EV subreddit post
      with dashboard screenshots, gauge willingness to pay before pricing.
- [ ] **Pricing decision** — one-time ($20-40) vs subscription. LeafSpy
      precedent favors one-time for prosumer trust.
- [ ] **ENET cable** (~$15) — Phase-3 credibility (behind-gateway access).
- [ ] CarPlay entitlement request (filed = free option on the future).

## Liability guardrails (before public release)

- Report language must stay descriptive ("measured 292 Ah between the SOC
  endpoints you entered"), never verdictive ("this battery is good/bad").
  No purchase advice. Disclaimer screen on first report export.
- Read-only invariant is a marketing asset: "physically cannot write to your
  car" — keep it prominent and true.
