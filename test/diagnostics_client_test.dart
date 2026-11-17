import 'dart:io';

import 'package:obd_battery_diagnostics/engine/diagnostics_client.dart';
import 'package:obd_battery_diagnostics/engine/signal_set.dart';
import 'package:obd_battery_diagnostics/transport/data_source.dart';
import 'package:test/test.dart';

SignalSet loadBmw() => SignalSet.parse(
    File('signalsets/BMW-330e-2018/v02.json').readAsStringSync());

/// Answers from a script that a test can change between polls, and counts
/// what was asked.
class _ScriptedSource implements DataSource {
  final Map<String, String> script;
  final List<String> sent = [];
  _ScriptedSource(this.script);

  @override
  String get name => 'scripted';
  @override
  bool get isConnected => true;
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<String> send(String command, {Duration? timeout}) async {
    sent.add(command);
    return script[command] ?? (command.startsWith('AT') ? 'OK\r>' : 'NO DATA\r>');
  }
}

void main() {
  group('DiagnosticsClient over ReplaySource (simulated SME)', () {
    late SignalSet set;
    setUpAll(() => set = loadBmw());

    test('reads and decodes SOC end-to-end', () async {
      // Scripted SME conversation with BMW extended addressing: the adapter
      // inserts the 07 (ATCEA07); the reply on 607 leads with the tester
      // address F1, after a 7F 22 78 response-pending, as on the real car.
      final source = ReplaySource({
        '22DDBC': '607 F1 03 7F 22 78 FF FF FF\r'
            '607 F1 10 09 62 DD BC 03 20\r'
            '607 F1 21 03 0C 00 F6 FF FF\r>',
      });
      await source.connect();
      final client = DiagnosticsClient(source, set);
      await client.initialize();

      final soc = set.commands
          .firstWhere((c) => c.signals.any((s) => s.id == 'HVBAT_SOC'));
      final readings = await client.read(soc, now: DateTime.utc(2026, 1, 1));

      expect(readings.map((r) => r.signal.id),
          ['HVBAT_SOC', 'HVBAT_SOC_WINDOW_MAX', 'HVBAT_SOC_WINDOW_MIN']);
      expect(readings[0].value, closeTo(80.0, 1e-9));
      expect(readings[0].unit, 'percent');
      expect(readings[1].value, closeTo(78.0, 1e-9));
      expect(readings[2].value, closeTo(24.6, 1e-9));

      // Verify addressing commands were issued.
      expect(source.sentLog, contains('ATSH6F1'));
      expect(source.sentLog, contains('ATCRA607'));
      // Auto-formatting off + flow control carrying the SME address.
      expect(
          source.sentLog,
          containsAllInOrder(
              ['ATCEA07', 'ATFCSH6F1', 'ATFCSD07300000', 'ATFCSM1']));
    });

    test('switches back to normal addressing for a J1979 PID', () async {
      final source = ReplaySource({
        '22DDBC': '607 F1 10 09 62 DD BC 03 20\r'
            '607 F1 21 03 0C 00 F6 FF FF\r>',
        '015B': '7EB 03 41 5B C7\r>',
      });
      await source.connect();
      final client = DiagnosticsClient(source, set);
      final soc = set.commands
          .firstWhere((c) => c.signals.any((s) => s.id == 'HVBAT_SOC'));
      final std = set.commands
          .firstWhere((c) => c.signals.any((s) => s.id == 'HVBAT_SOC_STD'));
      await client.read(soc);
      await client.read(soc); // same mode: no repeated mode commands
      expect(source.sentLog.where((c) => c == 'ATCEA07'), hasLength(1));
      final r = await client.read(std);
      expect(r.single.value, closeTo(78.0, 0.1));
      final i = source.sentLog.lastIndexOf('ATCEA');
      expect(i, greaterThan(source.sentLog.indexOf('ATCEA07')));
      expect(source.sentLog.indexOf('015B'), greaterThan(i));
    });

    // Multi-frame DFA0 (11 frames) is covered against the real capture in
    // bmw_sme_capture_test.dart.

    test('readAll skips failing commands via onFailure', () async {
      // Only SOC responds; everything else returns NO DATA.
      final source = ReplaySource({
        '22DDBC': '607 F1 10 09 62 DD BC 03 20\r'
            '607 F1 21 03 0C 00 F6 FF FF\r>',
      });
      // Default (unmapped) returns the benign prompt, which parseFrames treats
      // as no frames -> CommandFailure. Make the misses explicit NO DATA.
      final failures = <CommandFailure>[];
      await source.connect();
      final client = DiagnosticsClient(source, set);
      final all = await client.readAll(onFailure: failures.add);

      expect(all.containsKey('HVBAT_SOC'), isTrue);
      expect(failures, isNotEmpty); // the other DIDs weren't scripted
    });

    test('a command with a freq is re-read only once that time has passed',
        () async {
      const fast = '7E8 03 41 5B 80\r>';
      const slow = '7E8 06 62 DD B6 02 74 00 00\r>';
      final set = SignalSet.parse('''
{"vehicle": "freq-test", "protocol": {"canFormat": "11bit"}, "commands": [
  {"hdr": "7E0", "rax": "7E8", "cmd": {"01": "5B"},
   "signals": [{"id": "FAST", "name": "f", "fmt": {"len": 8}}]},
  {"hdr": "7E0", "rax": "7E8", "freq": 300, "cmd": {"22": "DDB6"},
   "signals": [{"id": "SLOW", "name": "s", "fmt": {"len": 16}}]}
]}''');
      final source = _ScriptedSource({'015B': fast});
      final client = DiagnosticsClient(source, set);
      int slowReads() => source.sent.where((c) => c == '22DDB6').length;
      final t0 = DateTime.utc(2026, 1, 1);

      // The slow command fails first: a failure does not start its clock.
      var all = await client.readAll(now: t0, onFailure: (_) {});
      expect(all.keys, ['FAST']);
      source.script['22DDB6'] = slow;
      all = await client.readAll(now: t0.add(const Duration(seconds: 2)));
      expect(all.keys, ['FAST', 'SLOW']);
      expect(all['SLOW']!.value, 628);
      expect(slowReads(), 2); // the failed try, then the good one

      // Within 300 s of the good read it is left out; the fast one is not.
      all = await client.readAll(now: t0.add(const Duration(seconds: 200)));
      expect(all.keys, ['FAST']);
      expect(slowReads(), 2);

      all = await client.readAll(now: t0.add(const Duration(seconds: 302)));
      expect(all.keys, ['FAST', 'SLOW']);
      expect(slowReads(), 3);

      // A fresh adapter init starts over.
      await client.initialize();
      all = await client.readAll(now: t0.add(const Duration(seconds: 303)));
      expect(all.keys, ['FAST', 'SLOW']);
    });
  });
}
