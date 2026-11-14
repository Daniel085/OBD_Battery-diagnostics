/// The extended-addressing reply wait: drive mode asks for the shortest one
/// that works, and a missed reply falls back to a longer one by itself.
/// Also: a reply must be for the request it is decoded as.
library;

import 'dart:io';

import 'package:obd_battery_diagnostics/engine/diagnostics_client.dart';
import 'package:obd_battery_diagnostics/engine/signal_set.dart';
import 'package:obd_battery_diagnostics/transport/data_source.dart';
import 'package:obd_battery_diagnostics/transport/simulated_source.dart';
import 'package:test/test.dart';

/// A BMW SME that answers `7F 22 78` (pending) at once and the real reply a
/// little later: the reply only makes it back if the adapter's wait (ATST)
/// is at least [needs].
class _SlowSme implements DataSource {
  final int needs;
  final List<int> reply;
  int wait = 0x32;
  final sent = <String>[];

  _SlowSme({required this.needs, List<int>? reply})
      // The real 2026-11-08 read: DD69 = FFFFFF6C (raw -1.48 A).
      : reply = reply ?? const [0x62, 0xDD, 0x69, 0xFF, 0xFF, 0xFF, 0x6C];

  List<String> get waits =>
      sent.where((c) => c.startsWith('ATST')).toList();

  @override
  String get name => 'slow SME';
  @override
  bool get isConnected => true;
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}

  @override
  Future<String> send(String command, {Duration? timeout}) async {
    sent.add(command);
    if (command.startsWith('ATST')) {
      wait = int.parse(command.substring(4), radix: 16);
    }
    if (command.startsWith('AT')) return 'OK\r>';
    String hex(List<int> b) =>
        b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');
    const pending = '607 F1 03 7F 22 78\r';
    final answer = '607 ${hex([0xF1, reply.length, ...reply])}\r';
    return wait >= needs ? '$pending$answer>' : '$pending>';
  }
}

/// Records what a wrapped source is sent.
class _Recorder implements DataSource {
  final DataSource inner;
  final sent = <String>[];
  _Recorder(this.inner);
  @override
  String get name => inner.name;
  @override
  bool get isConnected => inner.isConnected;
  @override
  Future<void> connect() => inner.connect();
  @override
  Future<void> disconnect() => inner.disconnect();
  @override
  Future<String> send(String command, {Duration? timeout}) {
    sent.add(command);
    return inner.send(command, timeout: timeout);
  }
}

void main() {
  final bmw = SignalSet.parse(
      File('signalsets/BMW-330e-2018/v02.json').readAsStringSync());
  final currentCmd = bmw.commands
      .firstWhere((c) => c.signals.any((s) => s.id == 'HVBAT_CURRENT'));

  Future<double> amps(DiagnosticsClient client) async =>
      (await client.read(currentCmd)).single.value;

  test('by default the safe wait is used and never shortened', () async {
    final sme = _SlowSme(needs: 0xFF);
    final client = DiagnosticsClient(sme, bmw);
    await client.initialize();
    for (var i = 0; i < 3; i++) {
      expect(await amps(client), closeTo(1.48, 1e-9));
    }
    expect(sme.waits, ['ATSTFF']);
  });

  test('fast timing uses the shortest wait when the ECU keeps up', () async {
    final sme = _SlowSme(needs: 0x40);
    final client = DiagnosticsClient(sme, bmw)..fastTiming = true;
    await client.initialize();
    for (var i = 0; i < 3; i++) {
      expect(await amps(client), closeTo(1.48, 1e-9));
    }
    expect(sme.waits, ['ATSTFF', 'ATST40']); // set once, then left alone
  });

  test('a missed reply falls back one step and stays there', () async {
    final sme = _SlowSme(needs: 0x80);
    final client = DiagnosticsClient(sme, bmw)..fastTiming = true;
    await client.initialize();
    // At 40 only the "pending" frame comes back: one lost sample.
    await expectLater(amps(client), throwsA(isA<CommandFailure>()));
    for (var i = 0; i < 3; i++) {
      expect(await amps(client), closeTo(1.48, 1e-9));
    }
    expect(sme.waits, ['ATSTFF', 'ATST40', 'ATST80']);
  });

  test('an ECU that needs the full wait ends up back on the default',
      () async {
    final sme = _SlowSme(needs: 0xFF);
    final client = DiagnosticsClient(sme, bmw)..fastTiming = true;
    await client.initialize();
    await expectLater(amps(client), throwsA(isA<CommandFailure>())); // at 40
    await expectLater(amps(client), throwsA(isA<CommandFailure>())); // at 80
    for (var i = 0; i < 3; i++) {
      expect(await amps(client), closeTo(1.48, 1e-9));
    }
    expect(sme.waits, ['ATSTFF', 'ATST40', 'ATST80', 'ATSTFF']);
  });

  test('turning fast timing off restores the safe wait on the next read',
      () async {
    final sme = _SlowSme(needs: 0x40);
    final client = DiagnosticsClient(sme, bmw)..fastTiming = true;
    await client.initialize();
    await amps(client);
    client.fastTiming = false;
    await amps(client);
    expect(sme.waits, ['ATSTFF', 'ATST40', 'ATSTFF']);
    // A failure on the safe wait (car asleep, say) does not burn a step.
    client.fastTiming = true;
    await amps(client);
    expect(sme.waits.last, 'ATST40');
  });

  test('a reply for a different request is rejected, not decoded', () async {
    // A late DDBC (SOC) answer surfacing in the DD69 (current) exchange:
    // decoded as current it would read as a wild value.
    final sme = _SlowSme(
        needs: 0, reply: const [0x62, 0xDD, 0xBC, 0x03, 0x8B, 0x03, 0x0C]);
    final client = DiagnosticsClient(sme, bmw);
    await client.initialize();
    await expectLater(
        amps(client),
        throwsA(isA<CommandFailure>().having((f) => '${f.cause}', 'cause',
            contains('Reply is for DDBC, not DD69'))));
  });

  test('normal addressing (Lyriq) never touches the reply wait', () async {
    final lyriq = SignalSet.parse(
        File('signalsets/Cadillac-Lyriq-2025/v02.json').readAsStringSync());
    final source = _Recorder(SimulatedLyriqSource());
    await source.connect();
    final client = DiagnosticsClient(source, lyriq)..fastTiming = true;
    await client.initialize();
    final all = await client.readAll();
    expect(all['HVBAT_CURRENT'], isNotNull);
    expect(source.sent.where((c) => c.startsWith('ATST')), isEmpty);
  });
}
