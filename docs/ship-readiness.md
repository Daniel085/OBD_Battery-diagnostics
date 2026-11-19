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
- [x] Dashboard hierarchy (pass 2): hero cards for pack current (+state/kW),
      SOH (measured > reported > prompt), SOC, temp range; compact rows for
      context signals. Widget-tested against the simulated Lyriq.
- [x] First-run onboarding (pass 2): 3 pages — what it does, adapter
      guidance, read-only promise. Shown once (marker file).
- [x] Shareable capacity result (pass 2): results card → PNG → share sheet,
      self-contained with app name + date.
- [x] Drive mode (pass 3): live EV power meter — fast-polls pack current
      alone (~5-15 Hz expected on a real adapter; on-screen Hz readout will
      measure it on-car), big kW draw/regen display, centered-zero power
      bar, 60 s rolling graph, session stats (peaks, kWh used vs recovered).
      Market rationale: the "Scan My Tesla" category (live power/battery
      telemetry, proven paid demand) is empty on Ultium, and Lyriq owners on
      Cadillac Forums explicitly ask for instantaneous-kW displays/graphs
      the dash lacks. Deliberately NOT a lap timer / 0-60 app — that space
      is owned by 10 Hz GPS+IMU products (Dragy, RaceChrono) and OBD is the
      wrong tool for it; wheel-speed-based 0-60 (1 km/h resolution) parked
      as a maybe-later, honestly-labeled extra.

## Code gaps (next passes)
- [ ] **Adapter compatibility UX**: detect clone quirks at connect (we already
      auto-diagnose GATT layouts) and explain silent NO DATA with the likely
      cause (car off, wrong vehicle, adapter held by another app). Do NOT
      blame clones for missing battery data: the Viecar clone read both cars,
      including Lyriq 29-bit multiframe (2026-11-19 copy review).
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

## TestFlight (internal testing) — status 2026-11-18

Code side done: unsigned `flutter build ios --release` builds (Flutter 3.50,
Xcode 27.2, plugins via Swift Package Manager — no CocoaPods needed), build
number set in `pubspec.yaml` (`0.1.0+1`; bump `+N` for every upload),
`ITSAppUsesNonExemptEncryption = false` so uploads skip the export-compliance
question, 1024 px icon has no alpha (still the Flutter default).

Remaining, all account-side (Daniel):
1. Xcode → Settings → Accounts: sign in with the Apple ID on team
   `EB25CFP6UQ` (needs a paid Apple Developer Program membership).
2. App Store Connect → Apps → New App: bundle id
   `com.obddiag.obdBatteryDiagnostics`, display name of choice.
3. `flutter build ipa --release`, then upload
   `build/ios/ipa/*.ipa` with Xcode Organizer or Transporter.
4. App Store Connect → TestFlight: add the tester (internal = already on the
   team; external = email + a one-time Beta App Review, needs a privacy
   policy URL and test notes, e.g. "use Demo mode, no car needed").
