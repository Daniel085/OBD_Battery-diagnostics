/// Keeps the phone from auto-locking while the app is connected to an
/// adapter. A locked phone suspends the app, and whatever it was reading or
/// recording stops with it. The lock button still works.
library;

import 'package:flutter/services.dart';

const _channel = MethodChannel('obd_battery_diagnostics/screen');

/// Best-effort: on a platform without the native half this does nothing.
Future<void> setKeepAwake(bool on) async {
  try {
    await _channel.invokeMethod<void>('keepAwake', on);
  } on MissingPluginException {
    // No native side (Android for now, tests).
  } on PlatformException {
    // Not worth failing a connection over.
  }
}
