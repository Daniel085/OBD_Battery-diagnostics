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

  ElmBleSource({
    required FlutterReactiveBle ble,
    required this.deviceId,
    required this.deviceName,
    ElmBleConfig? config,
  })  : _ble = ble,
        config = config ?? ElmBleConfig.ffe0();

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

    _writeChar = QualifiedCharacteristic(
      serviceId: config.serviceUuid,
      characteristicId: config.writeCharUuid,
      deviceId: deviceId,
    );
    _notifyChar = QualifiedCharacteristic(
      serviceId: config.serviceUuid,
      characteristicId: config.notifyCharUuid,
      deviceId: deviceId,
    );

    _notifySub =
        _ble.subscribeToCharacteristic(_notifyChar!).listen(_onData, onError: (Object e) {
      final p = _pending;
      if (p != null && !p.isCompleted) p.completeError(e);
    });

    _connected = true;
  }

  void _onData(List<int> bytes) {
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
    final completer = Completer<String>();
    _pending = completer;

    await _ble.writeCharacteristicWithoutResponse(
      _writeChar!,
      value: utf8.encode('$command\r'),
    );

    return completer.future.timeout(
      timeout ?? config.defaultTimeout,
      onTimeout: () {
        _pending = null;
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
