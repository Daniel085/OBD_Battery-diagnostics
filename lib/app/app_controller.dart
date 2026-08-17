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
import '../engine/logging.dart';
import '../engine/signal_set.dart';
import '../transport/data_source.dart';
import '../transport/elm_ble_source.dart';
import 'capacity_test_store.dart';
import 'signal_set_repository.dart';

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
  })  : _bleInstance = ble,
        repo = repository ?? SignalSetRepository();

  ConnectionPhase phase = ConnectionPhase.idle;
  String? errorMessage;

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

  final Map<String, Reading> latest = {};
  final InMemorySampleSink sessionLog = InMemorySampleSink();
  final List<CommandFailure> lastFailures = [];

  // ---- Capacity test ---------------------------------------------------------

  /// Persistence for the capacity test (null in tests → in-memory only).
  final CapacityTestStore? capacityStore;

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

  void startCapacityTest() {
    capacityTest = CapacityTestSession();
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

  /// The live transport (BLE or simulated), exposed for the RE scanner UI.
  DataSource? get activeSource => _source;

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
      _source = source;

      _signalSet = await repo.load(selectedVehicle!);
      _client = DiagnosticsClient(source, _signalSet!);

      _setPhase(ConnectionPhase.initializing);
      await _client!.initialize();

      _setPhase(ConnectionPhase.polling);
      _startPolling();
    } catch (e) {
      // Include the adapter's GATT table: when a clone doesn't match a known
      // layout, its real service/characteristic UUIDs are what we need to see.
      final gatt = source?.discoveredGatt;
      _fail('Connect failed: $e'
          '${gatt == null ? '' : '\n\nAdapter GATT:\n$gatt'}');
    }
  }

  /// Connect over an arbitrary (e.g. test/replay) source without BLE scanning.
  Future<void> connectWithSource(DataSource source, VehicleEntry vehicle) async {
    selectedVehicle = vehicle;
    try {
      _setPhase(ConnectionPhase.connecting);
      await source.connect();
      _source = source;
      _signalSet = await repo.load(vehicle);
      _client = DiagnosticsClient(source, _signalSet!);
      _setPhase(ConnectionPhase.initializing);
      await _client!.initialize();
      _setPhase(ConnectionPhase.polling);
      _startPolling();
    } catch (e) {
      _fail('Connect failed: $e');
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
    if (_pollInFlight) return;
    _pollInFlight = true;
    lastFailures.clear();
    try {
      final readings = await client.readAll(onFailure: lastFailures.add);
      latest.addAll(readings);
      if (readings.isNotEmpty) {
        await sessionLog.add(LogSample.fromReadings(readings));
        _feedCapacityTest(readings);
      }
      notifyListeners();
    } catch (e) {
      _fail('Poll failed: $e');
    } finally {
      _pollInFlight = false;
    }
  }

  Future<void> disconnect() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    await _source?.disconnect();
    _source = null;
    _client = null;
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
    );
  }

  // ---- helpers ---------------------------------------------------------------

  void _setPhase(ConnectionPhase p) {
    phase = p;
    if (p != ConnectionPhase.error) errorMessage = null;
    notifyListeners();
  }

  void _fail(String msg) {
    errorMessage = msg;
    phase = ConnectionPhase.error;
    notifyListeners();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _scanNotifyTimer?.cancel();
    _pollTimer?.cancel();
    _source?.disconnect();
    // Do not touch _ble here — the lazy getter would construct the real plugin.
    super.dispose();
  }
}
