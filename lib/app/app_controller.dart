/// Central app state: BLE discovery, adapter connection, the polling loop, the
/// latest readings, session logging, and report generation. UI observes this
/// via provider/ChangeNotifier.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import '../engine/battery_health.dart';
import '../engine/capacity_test.dart';
import '../engine/diagnostics_client.dart';
import '../engine/display_units.dart';
import '../engine/drive_record.dart';
import '../engine/drive_session.dart';
import '../engine/logging.dart';
import '../engine/signal_set.dart';
import '../engine/soh_history.dart';
import '../transport/data_source.dart';
import '../transport/elm_ble_source.dart';
import '../transport/recording_source.dart';
import 'capacity_test_store.dart';
import 'capture_store.dart';
import 'drive_record_store.dart';
import 'onboarding_store.dart';
import 'settings_store.dart';
import 'signal_set_repository.dart';
import 'soh_history_store.dart';

enum ConnectionPhase { idle, scanning, connecting, initializing, polling, error }

class AppController extends ChangeNotifier {
  /// Lazily constructed so unit/widget tests that never scan don't spin up the
  /// real BLE plugin (which starts platform timers). Inject one to override.
  FlutterReactiveBle? _bleInstance;
  FlutterReactiveBle get _ble => _bleInstance ??= FlutterReactiveBle();

  final SignalSetRepository repo;
  final BatteryHealthAnalyzer analyzer;

  AppController({
    FlutterReactiveBle? ble,
    SignalSetRepository? repository,
    this.analyzer = const BatteryHealthAnalyzer(),
    this.capacityStore,
    this.driveStore,
    this.onboardingStore,
    this.sohStore,
    this.settingsStore,
    this.captureStore,
    this.keepAwake,
    this.defaultUnits = const DisplayUnits(),
  })  : _bleInstance = ble,
        repo = repository ?? SignalSetRepository();

  // ---- Captures -------------------------------------------------------------

  /// Where session recordings, signal-check reports and sweeps are kept on
  /// the phone (null in tests → nothing is written).
  final CaptureStore? captureStore;

  /// Stops the phone from auto-locking while connected: a locked phone
  /// suspends the app and the capture with it. Null in tests.
  final void Function(bool on)? keepAwake;

  CaptureWriter? _recording;

  /// File name of the session recording in progress, if any.
  String? get recordingName => _recording?.name;

  /// Wrap [source] so that everything sent to the adapter and every reply
  /// goes into a capture file. Demo connections are not recorded. Recording
  /// is best-effort: if the file cannot be opened the session goes ahead.
  Future<DataSource> _recorded(DataSource source, SignalSet set) async {
    final store = captureStore;
    if (store == null || _demo) return source;
    try {
      final now = DateTime.now();
      final writer = await store
          .open(CaptureStore.fileName(now, set.vehicle, 'session'));
      writer
        ..line('# Session capture: everything sent to the adapter and what '
            'came back')
        ..line('# vehicle: ${set.vehicle}')
        ..line('# adapter: ${source.name}')
        ..line('# started: ${now.toIso8601String()}')
        ..line(Recording.formatNote);
      _recording = writer;
      return RecordingSource(source, writer.line);
    } on Object {
      return source;
    }
  }

  /// Add a note line to the session recording (what the user started when).
  void captureNote(String text) => _recording?.line(
      '# ${Recording.clock(DateTime.now())} ${text.replaceAll('\n', ' ')}');

  /// Write the recording's buffered lines to disk (before sharing the file).
  Future<void> flushRecording() async => _recording?.flush();

  /// Keep a finished report or sweep on the phone. Returns the file name, or
  /// null when nothing was saved (no store, demo connection, disk error).
  Future<String?> saveCapture(String kind, String text) async {
    final store = captureStore;
    if (store == null || _demo) return null;
    try {
      final name = CaptureStore.fileName(DateTime.now(),
          _signalSet?.vehicle ?? selectedVehicle?.id ?? 'vehicle', kind);
      await store.save(name, text);
      captureNote('saved $name');
      return name;
    } on Object {
      return null;
    }
  }

  /// Close the session recording; completes when its last line is on disk.
  Future<void> _endRecording() async {
    final writer = _recording;
    _recording = null;
    await writer?.close();
  }

  // ---- Settings --------------------------------------------------------------

  /// Persistence for app settings (null in tests → in-memory only).
  final SettingsStore? settingsStore;

  /// Units used until the user chooses: the device region's (main.dart), or
  /// Celsius and km when none is given.
  final DisplayUnits defaultUnits;

  /// How values are displayed. Display only: readings, logs and exports stay
  /// in the signal set's own units.
  late DisplayUnits units = defaultUnits;

  Future<void> restoreSettings() async {
    final store = settingsStore;
    if (store == null) return;
    units = await store.loadUnits(defaults: defaultUnits);
    notifyListeners();
  }

  void setTemperatureUnit(TemperatureUnit unit) {
    if (units.temperature == unit) return;
    units = units.copyWith(temperature: unit);
    notifyListeners();
    unawaited(_saveSettings());
  }

  void setDistanceUnit(DistanceUnit unit) {
    if (units.distance == unit) return;
    units = units.copyWith(distance: unit);
    notifyListeners();
    unawaited(_saveSettings());
  }

  Future<void> _saveSettings() async {
    try {
      await settingsStore?.saveUnits(units);
    } catch (_) {
      // Best-effort: the in-memory setting stays in effect this session.
    }
  }

  // ---- SoH history -----------------------------------------------------------

  /// Persistence for the SoH history (null in tests → in-memory only).
  final SohHistoryStore? sohStore;

  /// Every SoH figure seen, one entry per vehicle/source/day. Grows across
  /// connects and app restarts; the dashboard charts it.
  SohHistory sohHistory = SohHistory();

  Future<void> restoreSohHistory() async {
    final store = sohStore;
    if (store == null) return;
    final loaded = await store.load();
    // Keep anything recorded before the load finished.
    for (final e in sohHistory.entries) {
      loaded.record(e);
    }
    sohHistory = loaded;
    notifyListeners();
  }

  /// Signal ids that carry an SoH figure, and what kind. Generic ids (the
  /// signal sets map each vehicle onto them), so no vehicle logic here.
  static const _sohSignals = {
    'HVBAT_SOH': SohSource.reported,
    'HVBAT_BMS_HEALTH_INDEX': SohSource.bmsIndex,
  };

  /// The SoH sources the connected vehicle can produce: a capacity test
  /// always, plus whichever SoH signals its signal set defines. With no
  /// signal set loaded, all of them.
  Set<SohSource> get sohSources {
    final set = _signalSet;
    return {
      SohSource.measured,
      for (final MapEntry(key: id, value: source) in _sohSignals.entries)
        if (set == null || set.signalsById.containsKey(id)) source,
    };
  }

  /// True while connected to a simulated source (demo mode). Demo readings
  /// are shown but never written to the SoH history.
  bool get isDemo => _demo;
  bool _demo = false;

  /// Start a connection from a clean slate: readings left over from an
  /// earlier connection (possibly another vehicle) must not be shown, logged
  /// or recorded as this one's.
  void _beginConnection({required bool demo}) {
    unawaited(_endRecording());
    _demo = demo;
    latest.clear();
    lastFailures.clear();
    driveSession = null;
  }

  /// Record the current SoH figures into the history; saves only on change.
  void _recordSoh() {
    if (_demo) return;
    final vehicle = selectedVehicle?.id ?? _signalSet?.vehicle;
    if (vehicle == null) return;
    final now = DateTime.now();
    final odo = latest['ODOMETER']?.value;
    var changed = false;
    for (final MapEntry(key: id, value: source) in _sohSignals.entries) {
      final r = latest[id];
      if (r == null) continue;
      changed |= sohHistory.record(SohEntry(
          at: now,
          vehicle: vehicle,
          source: source,
          sohPct: r.value,
          odometerKm: odo));
    }
    final measured = capacityTest?.analyze().sohPct;
    if (measured != null) {
      changed |= sohHistory.record(SohEntry(
          at: now,
          vehicle: vehicle,
          source: SohSource.measured,
          sohPct: double.parse(measured.toStringAsFixed(1)),
          odometerKm: odo));
    }
    if (changed) unawaited(_saveSohHistory());
  }

  Future<void> _saveSohHistory() async {
    try {
      await sohStore?.save(sohHistory);
    } catch (_) {
      // Best-effort: the in-memory history stays authoritative this session.
    }
  }

  // ---- Onboarding ------------------------------------------------------------

  /// Null (tests) means onboarding never shows.
  final OnboardingStore? onboardingStore;

  /// True while first-run onboarding should be displayed.
  bool showOnboarding = false;

  Future<void> restoreOnboarding() async {
    final store = onboardingStore;
    if (store == null) return;
    if (!await store.isDone()) {
      showOnboarding = true;
      notifyListeners();
    }
  }

  void completeOnboarding() {
    showOnboarding = false;
    unawaited(onboardingStore?.markDone() ?? Future.value());
    notifyListeners();
  }

  ConnectionPhase phase = ConnectionPhase.idle;
  String? errorMessage;

  /// Technical detail behind [errorMessage] (exception text, adapter GATT
  /// table) — shown collapsed in the UI so failures read human-first.
  String? errorDetails;

  final List<DiscoveredDevice> discovered = [];
  StreamSubscription<DiscoveredDevice>? _scanSub;

  /// Scan results are coalesced: the BLE stream sets [_scanDirty] and a timer
  /// notifies listeners at most twice a second, so a busy RF environment can't
  /// swamp the UI thread with rebuilds.
  Timer? _scanNotifyTimer;
  bool _scanDirty = false;

  DataSource? _source;
  DiagnosticsClient? _client;
  Timer? _pollTimer;
  bool _pollInFlight = false;

  VehicleEntry? selectedVehicle;
  SignalSet? _signalSet;

  /// Equivalent full cycles computed from the latest readings and the signal
  /// set's rated capacity, or null when this vehicle provides neither.
  EquivalentCycles? get equivalentFullCycles =>
      BatteryHealthAnalyzer.equivalentFullCycles(latest, _signalSet?.ratedAh);

  final Map<String, Reading> latest = {};
  final InMemorySampleSink sessionLog = InMemorySampleSink();
  final List<CommandFailure> lastFailures = [];

  // ---- Capacity test ---------------------------------------------------------

  /// Persistence for the capacity test (null in tests → in-memory only).
  final CapacityTestStore? capacityStore;
  final DriveRecordStore? driveStore;

  /// The running (or finished-but-not-dismissed) capacity test, if any. It
  /// survives disconnects and app restarts; polls feed it HVBAT_CURRENT.
  CapacityTestSession? capacityTest;

  DateTime? _lastCapacitySample;
  DateTime? _lastCapacitySave;

  /// Minimum spacing between recorded samples — 2 s polling would bloat a
  /// 10 h session to ~18k samples for no accuracy gain at steady current.
  static const capacitySampleSpacing = Duration(seconds: 10);
  static const _capacitySaveSpacing = Duration(seconds: 60);

  /// Reload a persisted session (call once at startup).
  Future<void> restoreCapacityTest() async {
    final restored = await capacityStore?.load();
    if (restored != null) {
      capacityTest = restored;
      notifyListeners();
    }
  }

  /// The capacity test's settings for the loaded vehicle, from its signal
  /// set's `pack` data. Null when the set does not give them.
  CapacityTestConfig? get capacityConfig {
    final kwh = _signalSet?.ratedKwh, volts = _signalSet?.nominalVoltage;
    return kwh == null || volts == null
        ? null
        : CapacityTestConfig(ratedKwh: kwh, nominalPackVoltage: volts);
  }

  /// False for a vehicle whose signal set lacks the pack data the capacity
  /// test grades against (it would otherwise grade against another car's).
  bool get capacityTestAvailable =>
      _signalSet == null || capacityConfig != null;

  void startCapacityTest() {
    if (!capacityTestAvailable) return;
    capacityTest = CapacityTestSession(config: capacityConfig);
    _lastCapacitySample = null;
    unawaited(_saveCapacityTest());
    notifyListeners();
  }

  void setCapacitySoc({double? start, double? end}) {
    final t = capacityTest;
    if (t == null) return;
    if (start != null) t.socStartPct = start;
    if (end != null) t.socEndPct = end;
    unawaited(_saveCapacityTest());
    notifyListeners();
  }

  void finishCapacityTest() {
    capacityTest?.finish();
    unawaited(_saveCapacityTest());
    notifyListeners();
  }

  void discardCapacityTest() {
    capacityTest = null;
    unawaited(capacityStore?.clear() ?? Future.value());
    notifyListeners();
  }

  Future<void> _saveCapacityTest() async {
    final t = capacityTest;
    if (t == null) return;
    try {
      await capacityStore?.save(t);
    } catch (_) {
      // Persistence is best-effort; the in-memory session stays authoritative.
    }
  }

  // ---- Drive mode (fast power polling) ---------------------------------------

  /// Live power session while drive mode runs; survives leaving the screen
  /// (kept until reset) so a drive's stats can be reviewed afterwards.
  DriveSession? driveSession;

  bool _driveMode = false;
  bool get driveModeActive => _driveMode;

  /// Floor on the fast-poll cycle time. Real adapters take 50-100+ ms per
  /// round trip anyway; this only stops the simulated source from spinning
  /// the loop at absurd rates.
  static const _drivePollFloor = Duration(milliseconds: 50);

  /// Nominal fallback if no pack-voltage signal has been read yet.
  static const _fallbackPackVolts = 352.1;

  /// Signals with this id prefix (motor temperature, speed, torque) are read
  /// alongside pack current in drive mode, at a much lower rate.
  static const driveExtraPrefix = 'MOTOR_';

  /// Pack-current polling runs undisturbed for this long between two reads
  /// of the extra signals. Each visit pauses the power feed for as long as
  /// the reads take (on another ECU that includes re-addressing the adapter).
  Duration driveExtrasSpacing = const Duration(seconds: 4);

  /// An extra command that fails this many times in a row is dropped until
  /// drive mode is next started, so a vehicle that does not answer it stops
  /// paying for it.
  static const _driveExtraMaxFailures = 3;

  List<Command> _driveExtras = const [];
  final Map<Command, int> _driveExtraFailures = {};
  DateTime? _lastDriveExtras;

  /// True when this vehicle's signal set has extra drive-mode signals.
  bool get hasDriveExtras =>
      _signalSet?.signalsById.keys.any((id) => id.startsWith(driveExtraPrefix)) ??
      false;

  /// False once every extra command has been dropped for not answering.
  bool get driveExtrasResponding => _driveExtras.isNotEmpty;

  /// The latest extra drive-mode readings, in signal-set order.
  List<Reading> get driveExtraReadings => [
        for (final cmd in _signalSet?.commands ?? const <Command>[])
          for (final s in cmd.signals)
            if (s.id.startsWith(driveExtraPrefix))
              if (latest[s.id] case final r?) r,
      ];

  /// Switch the poll loop to hammering the pack-current command —
  /// the only way to get a usable live power feed over a serial adapter.
  /// Returns false if this vehicle has no pack-current signal.
  bool startDriveMode() {
    final client = _client;
    final set = _signalSet;
    if (_driveMode) return true;
    if (client == null || set == null) return false;
    Command? currentCmd;
    for (final cmd in set.commands) {
      if (cmd.signals.any((s) => s.id == 'HVBAT_CURRENT')) {
        currentCmd = cmd;
        break;
      }
    }
    if (currentCmd == null) return false;

    _driveExtras = [
      for (final cmd in set.commands)
        if (!identical(cmd, currentCmd) &&
            cmd.signals.any((s) => s.id.startsWith(driveExtraPrefix)))
          cmd,
    ];
    _driveExtraFailures.clear();
    // The first visit waits a full spacing so the power feed starts at once.
    _lastDriveExtras = DateTime.now();

    _driveMode = true;
    captureNote('drive mode on');
    // One signal polled in a loop: use the shortest reply wait that works.
    client.fastTiming = true;
    driveSession ??= DriveSession();
    _pollTimer?.cancel();
    _pollTimer = null;
    unawaited(_driveLoop(client, currentCmd));
    notifyListeners();
    return true;
  }

  /// Leave drive mode and resume the normal all-signals poll (if still
  /// connected). The session object stays for review.
  void stopDriveMode() {
    if (!_driveMode) return;
    _driveMode = false;
    captureNote('drive mode off');
    _client?.fastTiming = false; // the full poll goes back to the safe wait
    if (_client != null) _startPolling();
    notifyListeners();
  }

  void resetDriveSession() {
    driveSession?.reset();
    notifyListeners();
  }

  // ---- Drive recording (the buyer-facing report) -----------------------------

  /// A recorded drive, if one is being captured. Unlike [driveSession] (the
  /// live rolling view), this keeps every tick for a persisted, shareable
  /// Drive Health Report.
  DriveRecord? driveRecord;
  DateTime? _lastDriveSave;
  static const _driveSaveSpacing = Duration(seconds: 15);

  bool get isRecordingDrive => driveRecord != null && !driveRecord!.finished;

  /// Begin recording (also entering drive mode if not already). Returns false
  /// if drive mode couldn't start (no pack-current signal).
  bool startDriveRecording() {
    if (!_driveMode && !startDriveMode()) return false;
    driveRecord = DriveRecord(
      vehicle: selectedVehicle?.displayName ?? _signalSet?.vehicle,
    );
    _lastDriveSave = null;
    unawaited(_saveDriveRecord());
    notifyListeners();
    return true;
  }

  void finishDriveRecording() {
    driveRecord?.finish();
    unawaited(_saveDriveRecord());
    notifyListeners();
  }

  void discardDriveRecording() {
    driveRecord = null;
    unawaited(driveStore?.clear() ?? Future.value());
    notifyListeners();
  }

  Future<void> restoreDriveRecording() async {
    final restored = await driveStore?.load();
    if (restored != null) {
      driveRecord = restored;
      notifyListeners();
    }
  }

  void _recordDriveTick(Reading current, double kw) {
    final rec = driveRecord;
    if (rec == null || rec.finished) return;
    // Read whatever context signals the latest snapshot happens to hold; the
    // drive profile prioritises current, so temp/volts may be stale but are
    // still useful. tempC uses the confirmed-live pack temp (40E5), not 4127
    // (a constant setpoint, per docs/lyriq-re-log.md).
    final volts = latest['HVBAT_NOMINAL_VOLTAGE']?.value ??
        latest['HVBAT_VOLTAGE']?.value;
    final temp = latest['HVBAT_TEMP_3']?.value ??
        latest['HVBAT_TEMP_MAIN']?.value ??
        latest['HVBAT_CELLTEMP_MAX']?.value;
    final speed = latest['VEHICLE_SPEED']?.value;
    rec.add(DriveTick(
      t: current.timestamp,
      kw: kw,
      amps: current.value,
      volts: volts,
      tempC: temp,
      speedKmh: speed,
    ));
    final at = current.timestamp;
    final last = _lastDriveSave;
    if (last == null || at.difference(last) >= _driveSaveSpacing) {
      _lastDriveSave = at;
      unawaited(_saveDriveRecord());
    }
  }

  Future<void> _saveDriveRecord() async {
    final rec = driveRecord;
    if (rec == null) return;
    try {
      await driveStore?.save(rec);
    } catch (_) {
      // Persistence is best-effort; the in-memory record stays authoritative.
    }
  }

  Future<void> _driveLoop(DiagnosticsClient client, Command currentCmd) async {
    while (_driveMode && identical(_client, client)) {
      final cycleStart = DateTime.now();
      if (_pollInFlight || adapterHeld) {
        // A normal poll is still draining, or a tool has the adapter; wait
        // rather than overlap commands.
        await Future<void>.delayed(const Duration(milliseconds: 10));
        continue;
      }
      _pollInFlight = true;
      try {
        final readings = await client.read(currentCmd);
        Reading? current;
        for (final r in readings) {
          latest[r.signal.id] = r;
          if (r.signal.id == 'HVBAT_CURRENT') current = r;
        }
        if (current != null) {
          final volts = latest['HVBAT_NOMINAL_VOLTAGE']?.value ??
              latest['HVBAT_VOLTAGE']?.value ??
              _fallbackPackVolts;
          final kw = current.value * volts / 1000;
          driveSession?.addSample(current.timestamp, kw);
          _recordDriveTick(current, kw);
          // Drive-mode samples also serve an active capacity test.
          _feedCapacityTest({'HVBAT_CURRENT': current});
        }
        await _readDriveExtras(client);
        notifyListeners();
      } on CommandFailure {
        // Transient (bus busy, adapter hiccup): back off briefly, keep going.
        await Future<void>.delayed(const Duration(milliseconds: 200));
      } catch (e) {
        _driveMode = false;
        client.fastTiming = false;
        _fail(
          'Lost contact with the adapter during drive mode — reconnect and '
          'try again.',
          details: '$e',
        );
        return;
      } finally {
        _pollInFlight = false;
      }
      final elapsed = DateTime.now().difference(cycleStart);
      if (elapsed < _drivePollFloor) {
        await Future<void>.delayed(_drivePollFloor - elapsed);
      }
    }
  }

  /// Read the extra drive-mode commands if their turn has come. A command
  /// that keeps failing is dropped; an adapter-level error propagates.
  Future<void> _readDriveExtras(DiagnosticsClient client) async {
    final last = _lastDriveExtras;
    if (_driveExtras.isEmpty ||
        (last != null &&
            DateTime.now().difference(last) < driveExtrasSpacing)) {
      return;
    }
    for (final cmd in List.of(_driveExtras)) {
      if (!_driveMode || !identical(_client, client)) break;
      try {
        for (final r in await client.read(cmd)) {
          latest[r.signal.id] = r;
        }
        _driveExtraFailures.remove(cmd);
      } on CommandFailure {
        final n = (_driveExtraFailures[cmd] ?? 0) + 1;
        _driveExtraFailures[cmd] = n;
        if (n >= _driveExtraMaxFailures) _driveExtras.remove(cmd);
      }
    }
    // Measured from the end of the visit: the power feed always gets a full
    // spacing to itself, however long the extra reads took.
    _lastDriveExtras = DateTime.now();
  }

  /// Feed the pack-current reading from one poll into the active test,
  /// throttling sample density and disk writes.
  void _feedCapacityTest(Map<String, Reading> readings) {
    final t = capacityTest;
    final current = readings['HVBAT_CURRENT'];
    if (t == null || t.isFinished || current == null) return;
    final at = current.timestamp;
    final lastSample = _lastCapacitySample;
    if (lastSample != null && at.difference(lastSample) < capacitySampleSpacing) {
      return;
    }
    t.addSample(at, current.value);
    _lastCapacitySample = at;
    final lastSave = _lastCapacitySave;
    if (lastSave == null || at.difference(lastSave) >= _capacitySaveSpacing) {
      _lastCapacitySave = at;
      unawaited(_saveCapacityTest());
    }
  }

  Duration pollInterval = const Duration(seconds: 2);

  bool get isConnected => _source?.isConnected ?? false;

  /// The live transport (BLE or simulated, wrapped by the session recorder
  /// when one is running), exposed for the RE scanner UI.
  DataSource? get activeSource => _source;

  /// The BLE adapter behind [activeSource], for its own diagnostics.
  ElmBleSource? get bleSource => _bleSource;
  ElmBleSource? _bleSource;

  /// The connected vehicle's signal set (null before the first connection).
  SignalSet? get signalSet => _signalSet;

  // ---- Tools that talk to the adapter themselves ----------------------------

  int _adapterHolds = 0;

  /// True while a tool (terminal, DID scanner, signal check) has the adapter
  /// and the dashboard's own reads are paused.
  bool get adapterHeld => _adapterHolds > 0;

  /// Pause the app's own reads and wait for the one in flight to finish, so
  /// a tool can use the adapter alone: it takes one command at a time, and
  /// the tools change its header and filter. Pair with [releaseAdapter].
  Future<void> holdAdapter() async {
    _adapterHolds++;
    while (_pollInFlight) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Give the adapter back. The next poll sets header, filter and addressing
  /// again instead of trusting what it set before the tool ran.
  void releaseAdapter() {
    if (_adapterHolds == 0) return;
    if (--_adapterHolds == 0) _client?.forgetAdapterState();
  }

  /// Run [body] with the adapter held; see [holdAdapter].
  Future<T> withAdapter<T>(Future<T> Function(DataSource source) body) async {
    final source = _source;
    if (source == null) throw StateError('Not connected');
    await holdAdapter();
    try {
      return await body(source);
    } finally {
      releaseAdapter();
    }
  }

  /// Devices worth showing: named ones only (OBD adapters always advertise a
  /// name), in **stable first-seen order** so rows never reorder under the
  /// user's finger — RSSI fluctuates constantly and sorting by it made the list
  /// jump around and become impossible to tap. Likely OBD adapters are hoisted
  /// to the top once, by name, which is stable.
  List<DiscoveredDevice> get visibleDevices {
    final named =
        discovered.where((d) => d.name.trim().isNotEmpty).toList(growable: false);
    final likely = named.where((d) => looksLikeObdName(d.name)).toList();
    final rest = named.where((d) => !looksLikeObdName(d.name)).toList();
    return [...likely, ...rest].take(20).toList();
  }

  static const _obdNameHints = [
    'viecar', 'obd', 'elm', 'vlink', 'vgate', 'obdii', 'konnwei', 'veepeak',
    'obdlink', 'scan',
  ];

  /// True if a BLE advertised name looks like an OBD adapter.
  static bool looksLikeObdName(String name) {
    final n = name.toLowerCase();
    return _obdNameHints.any(n.contains);
  }

  void selectVehicle(VehicleEntry v) {
    selectedVehicle = v;
    notifyListeners();
  }

  // ---- BLE discovery ---------------------------------------------------------

  Future<void> startScan() async {
    discovered.clear();
    _scanDirty = false;
    _setPhase(ConnectionPhase.scanning);

    // The BLE stack reports `unknown` until iOS finishes initialising it (and
    // until the user answers the permission prompt). Scanning during that
    // window silently returns nothing — which is why the first tap used to do
    // nothing and only the second one worked. Wait for a settled state first.
    try {
      if (_ble.status != BleStatus.ready) {
        await _ble.statusStream
            .firstWhere((s) => s == BleStatus.ready)
            .timeout(const Duration(seconds: 10));
      }
    } on TimeoutException {
      _fail('Bluetooth not ready. Check that Bluetooth is on and this app has '
          'permission in Settings > Privacy & Security > Bluetooth.');
      return;
    } catch (e) {
      _fail('Bluetooth unavailable: $e');
      return;
    }

    _scanSub?.cancel();
    _scanSub = _ble.scanForDevices(withServices: []).listen((d) {
      // BLE advertisements arrive many times per second per device. Rebuilding
      // the UI on every packet locks up the main thread, so mutate the list
      // here and let a throttle timer coalesce the notifications.
      final idx = discovered.indexWhere((e) => e.id == d.id);
      if (idx >= 0) {
        // Existing device: only a metadata refresh, let the timer coalesce it.
        discovered[idx] = d;
        _scanDirty = true;
      } else {
        // A newly-seen device changes the list contents, so show it right away
        // rather than making the user wait (or tap Scan again) for a tick.
        discovered.add(d);
        notifyListeners();
      }
    }, onError: (Object e) => _fail('BLE scan failed: $e'));

    _scanNotifyTimer?.cancel();
    _scanNotifyTimer =
        Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_scanDirty) {
        _scanDirty = false;
        notifyListeners();
      }
    });
  }

  void stopScan() {
    _scanSub?.cancel();
    _scanSub = null;
    _scanNotifyTimer?.cancel();
    _scanNotifyTimer = null;
    if (phase == ConnectionPhase.scanning) _setPhase(ConnectionPhase.idle);
  }

  // ---- Connect + poll --------------------------------------------------------

  Future<void> connectAndStart(
    DiscoveredDevice device, {
    ElmBleConfig? bleConfig,
  }) async {
    if (selectedVehicle == null) {
      _fail('Select a vehicle first.');
      return;
    }
    stopScan();
    _beginConnection(demo: false);
    ElmBleSource? source;
    try {
      _setPhase(ConnectionPhase.connecting);
      source = ElmBleSource(
        ble: _ble,
        deviceId: device.id,
        deviceName: device.name,
        config: bleConfig,
      );
      await source.connect();
      _bleSource = source;
      _source = source;

      _signalSet = await repo.load(selectedVehicle!);
      _source = await _recorded(source, _signalSet!);
      _client = DiagnosticsClient(_source!, _signalSet!);

      _setPhase(ConnectionPhase.initializing);
      await _client!.initialize();

      _setPhase(ConnectionPhase.polling);
      keepAwake?.call(true);
      _startPolling();
    } catch (e) {
      // Human-readable summary up front; the exception and the adapter's GATT
      // table (the thing that identifies an unknown clone layout) go into the
      // collapsible details.
      final gatt = source?.discoveredGatt;
      _fail(
        'Could not connect to "${device.name.isEmpty ? device.id : device.name}". '
        'Check the adapter is plugged into the OBD port, the car is on, and '
        'no other app is using the adapter — then scan again.',
        details: '$e${gatt == null ? '' : '\n\nAdapter GATT:\n$gatt'}',
      );
    }
  }

  /// Connect over an arbitrary (e.g. test/replay) source without BLE scanning.
  ///
  /// Pass [demo] for a simulated source: its readings are displayed like any
  /// other but are not saved to the SoH history.
  Future<void> connectWithSource(DataSource source, VehicleEntry vehicle,
      {bool demo = false}) async {
    selectedVehicle = vehicle;
    _beginConnection(demo: demo);
    try {
      _setPhase(ConnectionPhase.connecting);
      await source.connect();
      _source = source;
      _signalSet = await repo.load(vehicle);
      _source = await _recorded(source, _signalSet!);
      _client = DiagnosticsClient(_source!, _signalSet!);
      _setPhase(ConnectionPhase.initializing);
      await _client!.initialize();
      _setPhase(ConnectionPhase.polling);
      keepAwake?.call(true);
      _startPolling();
    } catch (e) {
      _fail('Connect failed.', details: '$e');
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(pollInterval, (_) => _pollOnce());
    _pollOnce();
  }

  Future<void> _pollOnce() async {
    final client = _client;
    if (client == null) return;
    // Re-entrancy guard: a poll can outlast the poll interval (6 sequential UDS
    // reads, each up to a 5 s adapter timeout), so a periodic tick may fire
    // while the previous poll is still in flight. Skip it rather than issue
    // overlapping commands on the single-command-at-a-time transport.
    if (_pollInFlight || adapterHeld) return;
    _pollInFlight = true;
    lastFailures.clear();
    try {
      final readings = await client.readAll(onFailure: lastFailures.add);
      // Disconnected (or reconnected) while this poll was in flight: its
      // results belong to a connection that is gone.
      if (!identical(_client, client)) return;
      latest.addAll(readings);
      if (readings.isNotEmpty) {
        await sessionLog.add(LogSample.fromReadings(readings));
        _feedCapacityTest(readings);
        _recordSoh();
      }
      notifyListeners();
    } catch (e) {
      if (!identical(_client, client)) return;
      _fail(
        'Lost contact with the adapter while reading — check it is still '
        'plugged in and reconnect.',
        details: '$e',
      );
    } finally {
      _pollInFlight = false;
    }
  }

  Future<void> disconnect() async {
    _driveMode = false;
    _pollTimer?.cancel();
    _pollTimer = null;
    await _source?.disconnect();
    _source = null;
    _bleSource = null;
    _client = null;
    await _endRecording();
    keepAwake?.call(false);
    _setPhase(ConnectionPhase.idle);
  }

  // ---- Report ----------------------------------------------------------------

  HealthReport buildReport({String? vin}) {
    // Fold the measured capacity/SOH in when a test has produced one — the
    // measured number beats any heuristic and belongs in the report.
    final extra = <String, double?>{};
    final capacity = capacityTest?.analyze();
    if (capacity?.sohPct != null) {
      extra['measured_soh_percent'] = capacity!.sohPct;
      extra['measured_capacity_kwh'] = capacity.packKwh;
      extra['measured_capacity_ah'] = capacity.packAh;
    }
    return analyzer.analyze(
      vehicle: selectedVehicle?.id ?? _signalSet?.vehicle ?? 'unknown',
      readings: Map.of(latest),
      vin: vin,
      extraMetrics: extra,
      units: units,
      ratedAh: _signalSet?.ratedAh,
    );
  }

  // ---- helpers ---------------------------------------------------------------

  void _setPhase(ConnectionPhase p) {
    phase = p;
    if (p != ConnectionPhase.error) {
      errorMessage = null;
      errorDetails = null;
    }
    notifyListeners();
  }

  void _fail(String msg, {String? details}) {
    errorMessage = msg;
    errorDetails = details;
    phase = ConnectionPhase.error;
    _recording?.line('# ${Recording.clock(DateTime.now())} app error: $msg');
    keepAwake?.call(false);
    notifyListeners();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _scanNotifyTimer?.cancel();
    _pollTimer?.cancel();
    _source?.disconnect();
    unawaited(_endRecording());
    // Do not touch _ble here — the lazy getter would construct the real plugin.
    super.dispose();
  }
}
