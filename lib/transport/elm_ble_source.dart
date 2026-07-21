/// Real BLE transport to an ELM327-style adapter via flutter_reactive_ble.
///
/// Implements the [DataSource] contract: connect, write a command line, and
/// accumulate notification bytes until the ELM327 `>` prompt is received.
///
/// BLE ELM327 clones vary in their GATT layout. Defaults target the common
/// Nordic-UART-like layout (FFE0/FFE1 combined write+notify). Override the
/// UUIDs if your adapter differs (e.g. genuine OBDLink uses a different set).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import 'data_source.dart';
import 'elm327_protocol.dart';

class ElmBleConfig {
  final Uuid serviceUuid;
  final Uuid writeCharUuid;
  final Uuid notifyCharUuid;
  final Duration defaultTimeout;

  const ElmBleConfig({
    required this.serviceUuid,
    required this.writeCharUuid,
    required this.notifyCharUuid,
    this.defaultTimeout = const Duration(seconds: 5),
  });

  /// The most common cheap-clone layout: single FFE1 characteristic on FFE0
  /// used for both write (no response) and notify.
  factory ElmBleConfig.ffe0() => ElmBleConfig(
        serviceUuid: Uuid.parse('0000ffe0-0000-1000-8000-00805f9b34fb'),
        writeCharUuid: Uuid.parse('0000ffe1-0000-1000-8000-00805f9b34fb'),
        notifyCharUuid: Uuid.parse('0000ffe1-0000-1000-8000-00805f9b34fb'),
      );

  /// Viecar / many "BT 4.0" clones: FFF0 service with FFF1 (notify) and FFF2
  /// (write). Some units combine both on FFF1 — connect-time discovery
  /// (see ElmBleSource._resolveCharacteristics) corrects the split if needed.
  factory ElmBleConfig.fff0() => ElmBleConfig(
        serviceUuid: Uuid.parse('0000fff0-0000-1000-8000-00805f9b34fb'),
        writeCharUuid: Uuid.parse('0000fff2-0000-1000-8000-00805f9b34fb'),
        notifyCharUuid: Uuid.parse('0000fff1-0000-1000-8000-00805f9b34fb'),
      );

  /// Nordic UART Service layout (some BLE adapters / OBDLink CX).
  factory ElmBleConfig.nordicUart() => ElmBleConfig(
        serviceUuid: Uuid.parse('6e400001-b5a3-f393-e0a9-e50e24dcca9e'),
        writeCharUuid: Uuid.parse('6e400002-b5a3-f393-e0a9-e50e24dcca9e'),
        notifyCharUuid: Uuid.parse('6e400003-b5a3-f393-e0a9-e50e24dcca9e'),
      );
}

class ElmBleSource implements DataSource {
  final FlutterReactiveBle _ble;
  final String deviceId;
  final String deviceName;
  final ElmBleConfig config;

  StreamSubscription<ConnectionStateUpdate>? _connSub;
  StreamSubscription<List<int>>? _notifySub;
  QualifiedCharacteristic? _writeChar;
  QualifiedCharacteristic? _notifyChar;

  final StringBuffer _rx = StringBuffer();
  Completer<String>? _pending;
  bool _connected = false;

  /// Incremented for every command. Notifications are only accepted while a
  /// command is in flight; on timeout the generation advances so late bytes
  /// from the abandoned command are dropped instead of leaking into the next
  /// command's response buffer.
  int _generation = 0;

  ElmBleSource({
    required FlutterReactiveBle ble,
    required this.deviceId,
    required this.deviceName,
    ElmBleConfig? config,
  })  : _ble = ble,
        config = config ?? ElmBleConfig.fff0();

  @override
  String get name => deviceName.isEmpty ? deviceId : deviceName;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect() async {
    final ready = Completer<void>();
    _connSub = _ble
        .connectToDevice(
      id: deviceId,
      connectionTimeout: const Duration(seconds: 15),
    )
        .listen((update) {
      switch (update.connectionState) {
        case DeviceConnectionState.connected:
          if (!ready.isCompleted) ready.complete();
          break;
        case DeviceConnectionState.disconnected:
          _connected = false;
          if (!ready.isCompleted) {
            ready.completeError(StateError('Disconnected during connect'));
          }
          break;
        default:
          break;
      }
    }, onError: (Object e) {
      if (!ready.isCompleted) ready.completeError(e);
    });

    await ready.future;

    await _resolveCharacteristics();

    _notifySub =
        _ble.subscribeToCharacteristic(_notifyChar!).listen(_onData, onError: (Object e) {
      final p = _pending;
      if (p != null && !p.isCompleted) p.completeError(e);
    });

    _connected = true;
  }

  /// Discover the adapter's GATT layout and pick the write + notify
  /// characteristics automatically, so we adapt to whatever this particular
  /// clone exposes (FFF1/FFF2 split, single FFF1, FFE1, etc.). Falls back to
  /// the configured UUIDs if discovery yields nothing usable.
  Future<void> _resolveCharacteristics() async {
    try {
      await _ble.discoverAllServices(deviceId);
      final services = await _ble.getDiscoveredServices(deviceId);

      // Record the full GATT table for diagnostics — when an adapter doesn't
      // match any known layout this is what tells us its real UUIDs.
      final log = StringBuffer();
      for (final s in services) {
        log.writeln('service ${s.id}');
        for (final ch in s.characteristics) {
          log.writeln('  char ${ch.id} '
              'w=${ch.isWritableWithoutResponse || ch.isWritableWithResponse} '
              'n=${ch.isNotifiable || ch.isIndicatable}');
        }
      }
      discoveredGatt = log.toString();

      // Only consider services that plausibly carry the serial link: the
      // configured one first, then other vendor (non-standard-16-bit) services.
      // Generic services like Device Information / Battery also expose
      // notifiable characteristics and must not win.
      bool isCandidateService(Uuid id) {
        final s = id.toString().toLowerCase();
        if (s == config.serviceUuid.toString().toLowerCase()) return true;
        return s.startsWith('0000fff') || // FFF0 family (Viecar and friends)
            s.startsWith('0000ffe') || // FFE0 family (common clones)
            s.startsWith('6e400001'); // Nordic UART
      }

      QualifiedCharacteristic? write;
      QualifiedCharacteristic? notify;
      for (final preferConfigured in [true, false]) {
        for (final s in services) {
          final matches = preferConfigured
              ? s.id.toString().toLowerCase() ==
                  config.serviceUuid.toString().toLowerCase()
              : isCandidateService(s.id);
          if (!matches) continue;
          for (final ch in s.characteristics) {
            final q = QualifiedCharacteristic(
              serviceId: s.id,
              characteristicId: ch.id,
              deviceId: deviceId,
            );
            if (notify == null && (ch.isNotifiable || ch.isIndicatable)) {
              notify = q;
            }
            if (write == null &&
                (ch.isWritableWithoutResponse || ch.isWritableWithResponse)) {
              write = q;
            }
          }
        }
        if (write != null && notify != null) break;
      }

      if (write != null || notify != null) {
        // If only one usable characteristic exists, share it for both roles.
        _notifyChar = notify ?? write;
        _writeChar = write ?? notify;
        return;
      }
      // Discovery found nothing usable — fall through to configured UUIDs.
    } catch (e) {
      discoveredGatt = 'GATT discovery failed: $e';
    }
    _writeChar = _fallback(config.writeCharUuid);
    _notifyChar = _fallback(config.notifyCharUuid);
  }

  /// Human-readable dump of the last GATT discovery, for troubleshooting an
  /// adapter whose layout we don't recognise. Surfaced in the UI on failure.
  String? discoveredGatt;

  QualifiedCharacteristic _fallback(Uuid charUuid) => QualifiedCharacteristic(
        serviceId: config.serviceUuid,
        characteristicId: charUuid,
        deviceId: deviceId,
      );

  void _onData(List<int> bytes) {
    // Drop any notification that arrives while no command is in flight (e.g. a
    // late frame from a command that already timed out).
    if (_pending == null) return;
    _rx.write(utf8.decode(bytes, allowMalformed: true));
    final text = _rx.toString();
    if (text.contains(elmPrompt)) {
      final p = _pending;
      _pending = null;
      _rx.clear();
      if (p != null && !p.isCompleted) p.complete(text);
    }
  }

  @override
  Future<String> send(String command, {Duration? timeout}) async {
    if (!_connected || _writeChar == null) {
      throw StateError('ElmBleSource not connected');
    }
    if (_pending != null) {
      throw StateError('A command is already in flight');
    }
    _rx.clear();
    final generation = ++_generation;
    final completer = Completer<String>();
    _pending = completer;

    await _ble.writeCharacteristicWithoutResponse(
      _writeChar!,
      value: utf8.encode('$command\r'),
    );

    return completer.future.timeout(
      timeout ?? config.defaultTimeout,
      onTimeout: () {
        // Only tear down if this timeout belongs to the still-current command
        // (a response may have raced in and started the next command already).
        if (_generation == generation) {
          _pending = null;
          _rx.clear();
        }
        throw TimeoutException('ELM327 command timed out: $command');
      },
    );
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    await _notifySub?.cancel();
    await _connSub?.cancel();
    _notifySub = null;
    _connSub = null;
  }
}
