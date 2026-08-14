/// Real TCP socket adapter for [DoipSource], backed by dart:io. Thin by design:
/// all DoIP logic lives in doip_source.dart / doip.dart; this just moves bytes.
///
/// (Not imported by the pure-Dart test suite — the fake gateway covers the
/// protocol. This is what the app uses on a device with an ENET cable.)
library;

import 'dart:async';
import 'dart:io';

import 'doip_source.dart';

class TcpDoipSocket implements DoipSocket {
  Socket? _socket;

  @override
  Future<void> connect(String host, int port, {Duration? timeout}) async {
    _socket = await Socket.connect(host, port,
        timeout: timeout ?? const Duration(seconds: 5));
    _socket!.setOption(SocketOption.tcpNoDelay, true);
  }

  @override
  Stream<List<int>> get inbound {
    final s = _socket;
    if (s == null) throw StateError('TcpDoipSocket not connected');
    return s;
  }

  @override
  void add(List<int> bytes) => _socket?.add(bytes);

  @override
  Future<void> close() async {
    await _socket?.flush();
    await _socket?.close();
    _socket?.destroy();
    _socket = null;
  }
}
