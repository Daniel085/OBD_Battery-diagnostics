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

/// Plain description of one discovered characteristic, decoupled from
/// flutter_reactive_ble types so role selection is a pure, testable function.
class GattCharInfo {
  final String serviceId;
  final String charId;
  final bool writeNoResp;
  final bool writeResp;
  final bool notify;

  const GattCharInfo({
    required this.serviceId,
    required this.charId,
    this.writeNoResp = false,
    this.writeResp = false,
    this.notify = false,
  });

  bool get writable => writeNoResp || writeResp;

  @override
  String toString() =>
      '$serviceId/$charId${writeNoResp ? ' wnr' : ''}${writeResp ? ' w' : ''}'
      '${notify ? ' n' : ''}';
}

/// The write + notify characteristics chosen for the serial link. They may be
/// the same characteristic (single FFE1-style layouts).
class ResolvedGattRoles {
  final GattCharInfo write;
  final GattCharInfo notify;
  const ResolvedGattRoles({required this.write, required this.notify});
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

  /// Whether the chosen write characteristic supports write-with-response —
  /// used by the one-shot fallback when write-without-response goes unheard.
  bool _writeSupportsResponse = false;
  bool _writeWithResponse = false;
  bool _everReceived = false;

  /// Rolling log of BLE-level events (TX, RX, role selection) kept for the
  /// diagnostics dump. Capped so a long session can't grow it unbounded.
  final List<String> _bleLog = [];
  static const _bleLogCap = 200;

  void _logBle(String line) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    _bleLog.add('$ts $line');
    if (_bleLog.length > _bleLogCap) _bleLog.removeAt(0);
  }

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
    _logBle('link connected');

    await _resolveCharacteristics();

    _notifySub =
        _ble.subscribeToCharacteristic(_notifyChar!).listen(_onData, onError: (Object e) {
      _logBle('notify error: $e');
      final p = _pending;
      if (p != null && !p.isCompleted) p.completeError(e);
    });
    _logBle('subscribed to ${_notifyChar!.characteristicId}');

    // Cheap clones need a beat between the CCCD write and the first command;
    // sending immediately can lose the command or the response.
    await Future<void>.delayed(const Duration(milliseconds: 300));

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

      final infos = <GattCharInfo>[
        for (final s in services)
          for (final ch in s.characteristics)
            GattCharInfo(
              serviceId: s.id.toString().toLowerCase(),
              charId: ch.id.toString().toLowerCase(),
              writeNoResp: ch.isWritableWithoutResponse,
              writeResp: ch.isWritableWithResponse,
              notify: ch.isNotifiable || ch.isIndicatable,
            ),
      ];

      final roles = pickRoles(
        infos,
        serviceUuid: config.serviceUuid.toString().toLowerCase(),
        writeCharUuid: config.writeCharUuid.toString().toLowerCase(),
        notifyCharUuid: config.notifyCharUuid.toString().toLowerCase(),
      );

      if (roles != null) {
        _writeChar = QualifiedCharacteristic(
          serviceId: Uuid.parse(roles.write.serviceId),
          characteristicId: Uuid.parse(roles.write.charId),
          deviceId: deviceId,
        );
        _notifyChar = QualifiedCharacteristic(
          serviceId: Uuid.parse(roles.notify.serviceId),
          characteristicId: Uuid.parse(roles.notify.charId),
          deviceId: deviceId,
        );
        _writeSupportsResponse = roles.write.writeResp;
        // Start without-response when supported (the gatttool-proven path).
        _writeWithResponse = !roles.write.writeNoResp;
        _logBle('roles: write=${roles.write} notify=${roles.notify}');
        return;
      }
      _logBle('roles: discovery found nothing usable, using configured UUIDs');
      // Discovery found nothing usable — fall through to configured UUIDs.
    } catch (e) {
      discoveredGatt = 'GATT discovery failed: $e';
      _logBle('GATT discovery failed: $e');
    }
    _writeChar = _fallback(config.writeCharUuid);
    _notifyChar = _fallback(config.notifyCharUuid);
    // Unknown layout: allow the with-response fallback to be tried.
    _writeSupportsResponse = true;
  }

  /// Choose the write + notify characteristics for the ELM serial link.
  ///
  /// Pure and static so it can be unit-tested against real adapter GATT
  /// tables. Policy, in descending weight:
  ///  * a characteristic exactly matching the configured UUID for its role;
  ///  * living in the configured service, over other vendor services
  ///    (FFF0/FFE0 families, Nordic UART — never Device Info/Battery etc.);
  ///  * for write: a characteristic DISTINCT from the notify characteristic.
  ///    Clones often advertise write on the notify characteristic (FFF1) but
  ///    only accept commands on the dedicated one (FFF2) — picking "first
  ///    writable" sends commands into a black hole;
  ///  * for write: supporting write-without-response (the proven path).
  ///
  /// Falls back to sharing one characteristic for both roles (FFE1-style
  /// single-characteristic layouts). Returns null if no candidate service
  /// exposes both a writable and a notifiable characteristic.
  static ResolvedGattRoles? pickRoles(
    List<GattCharInfo> chars, {
    required String serviceUuid,
    required String writeCharUuid,
    required String notifyCharUuid,
  }) {
    bool isCandidateService(String s) {
      if (s == serviceUuid) return true;
      return s.startsWith('0000fff') || // FFF0 family (Viecar and friends)
          s.startsWith('0000ffe') || // FFE0 family (common clones)
          s.startsWith('6e400001'); // Nordic UART
    }

    final candidates =
        chars.where((c) => isCandidateService(c.serviceId)).toList();

    int base(GattCharInfo c, String exactUuid) {
      var score = 0;
      if (c.charId == exactUuid) score += 8;
      if (c.serviceId == serviceUuid) score += 4;
      return score;
    }

    GattCharInfo? best(
        Iterable<GattCharInfo> from, int Function(GattCharInfo) score) {
      GattCharInfo? winner;
      var bestScore = -1;
      for (final c in from) {
        final s = score(c);
        if (s > bestScore) {
          winner = c;
          bestScore = s;
        }
      }
      return winner;
    }

    final notify = best(
      candidates.where((c) => c.notify),
      (c) => base(c, notifyCharUuid),
    );
    if (notify == null) return null;

    final write = best(
      candidates.where((c) => c.writable),
      (c) =>
          base(c, writeCharUuid) +
          (c.charId != notify.charId || c.serviceId != notify.serviceId
              ? 5
              : 0) +
          (c.writeNoResp ? 2 : 0),
    );
    if (write == null) return null;

    return ResolvedGattRoles(write: write, notify: notify);
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
    _everReceived = true;
    final printable = utf8
        .decode(bytes, allowMalformed: true)
        .replaceAll('\r', r'\r')
        .replaceAll('\n', r'\n');
    _logBle('rx ${bytes.length}B "$printable"'
        '${_pending == null ? ' (unsolicited, dropped)' : ''}');
    // Drop any notification that arrives while no command is in flight (e.g. a
    // late frame from a command that already timed out, or the ELM banner).
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
    try {
      return await _sendOnce(command, timeout: timeout);
    } on TimeoutException {
      // If we have NEVER heard a byte from this adapter, the write itself may
      // be the problem — some clone/iOS combinations silently drop
      // write-without-response. Flip to write-with-response once and retry;
      // if that works it stays flipped for the session.
      if (!_everReceived && !_writeWithResponse && _writeSupportsResponse) {
        _writeWithResponse = true;
        _logBle('timeout with no RX ever — retrying "$command" with-response');
        return _sendOnce(command, timeout: timeout);
      }
      rethrow;
    }
  }

  Future<String> _sendOnce(String command, {Duration? timeout}) async {
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

    _logBle('tx${_writeWithResponse ? ' (with-response)' : ''} "$command"');
    final payload = utf8.encode('$command\r');
    if (_writeWithResponse) {
      await _ble.writeCharacteristicWithResponse(_writeChar!, value: payload);
    } else {
      await _ble.writeCharacteristicWithoutResponse(_writeChar!, value: payload);
    }

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

  /// Everything needed to diagnose a silent adapter in one dump: the GATT
  /// table, which characteristics we chose for which role, the write mode,
  /// and the recent TX/RX log (including unsolicited bytes). Surfaced by the
  /// terminal screen.
  String diagnosticsDump() {
    final b = StringBuffer()
      ..writeln('device: $deviceName ($deviceId)')
      ..writeln('config service=${config.serviceUuid} '
          'write=${config.writeCharUuid} notify=${config.notifyCharUuid}')
      ..writeln('chosen write=${_writeChar?.characteristicId} '
          '(${_writeWithResponse ? 'with' : 'without'}-response) '
          'notify=${_notifyChar?.characteristicId}')
      ..writeln('ever received bytes: $_everReceived')
      ..writeln('--- GATT ---')
      ..writeln(discoveredGatt ?? '(no discovery run)')
      ..writeln('--- BLE log (last ${_bleLog.length}) ---');
    _bleLog.forEach(b.writeln);
    return b.toString();
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
