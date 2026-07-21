/// Central app state: BLE discovery, adapter connection, the polling loop, the
/// latest readings, session logging, and report generation. UI observes this
/// via provider/ChangeNotifier.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import '../engine/battery_health.dart';
import '../engine/diagnostics_client.dart';
import '../engine/logging.dart';
import '../engine/signal_set.dart';
import '../transport/data_source.dart';
import '../transport/elm_ble_source.dart';
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

  Duration pollInterval = const Duration(seconds: 2);

  bool get isConnected => _source?.isConnected ?? false;

  /// The live transport (BLE or simulated), exposed for the RE scanner UI.
  DataSource? get activeSource => _source;

  /// Devices worth showing: named ones first (OBD adapters always advertise a
  /// name), strongest signal first, capped so a busy RF environment doesn't
  /// render dozens of irrelevant beacons.
  List<DiscoveredDevice> get visibleDevices {
    final named = discovered.where((d) => d.name.trim().isNotEmpty).toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    return named.take(15).toList();
  }

  void selectVehicle(VehicleEntry v) {
    selectedVehicle = v;
    notifyListeners();
  }

  // ---- BLE discovery ---------------------------------------------------------

  void startScan() {
    discovered.clear();
    _scanDirty = false;
    _setPhase(ConnectionPhase.scanning);
    _scanSub?.cancel();
    _scanSub = _ble.scanForDevices(withServices: []).listen((d) {
      // BLE advertisements arrive many times per second per device. Rebuilding
      // the UI on every packet locks up the main thread, so mutate the list
      // here and let a throttle timer coalesce the notifications.
      final idx = discovered.indexWhere((e) => e.id == d.id);
      if (idx >= 0) {
        discovered[idx] = d;
      } else {
        discovered.add(d);
      }
      _scanDirty = true;
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
    return analyzer.analyze(
      vehicle: selectedVehicle?.id ?? _signalSet?.vehicle ?? 'unknown',
      readings: Map.of(latest),
      vin: vin,
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
