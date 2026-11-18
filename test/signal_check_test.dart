/// The signal check (lib/tools/signal_check.dart): every request of a signal
/// set sent once, each outcome classified, and a report whose raw replies can
/// be replayed. Uses the Ford hybrid set, where the check matters most: its
/// hybrid-battery requests are guesses from a sibling model.
library;

import 'dart:convert';
import 'dart:io';

import 'package:obd_battery_diagnostics/engine/diagnostics_client.dart';
import 'package:obd_battery_diagnostics/engine/signal_set.dart';
import 'package:obd_battery_diagnostics/tools/signal_check.dart';
import 'package:obd_battery_diagnostics/transport/data_source.dart';
import 'package:test/test.dart';

/// A truck that answers what OBDb captured on real F-150s, one hybrid-battery
/// request (made up here), rejects another, and is silent on the rest.
Map<String, String> truck() {
  final fixtures = jsonDecode(
      File('test/fixtures/obdb/Ford-F-150-Hybrid-2021.json')
          .readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final c in (fixtures['cases'] as List).reversed)
      c['request'] as String: '${c['response']}\r>',
    '224801': '7EC 05 62 48 01 5A 3C\r>', // answered
    '22490C': '7EC 03 7F 22 31\r>', // rejected: request out of range
    '22480D': 'CAN ERROR\r>', // failed
    'ATRV': '12.4V\r>',
    'ATDPN': 'A6\r>',
  };
}

/// Anything not scripted gets the adapter's NO DATA.
class _Truck extends ReplaySource {
  _Truck() : super(truck());
  @override
  Future<String> send(String command, {Duration? timeout}) async {
    final reply = await super.send(command, timeout: timeout);
    final isRequest = !command.toUpperCase().startsWith('AT');
    return isRequest && reply == '\r>' ? 'NO DATA\r>' : reply;
  }
}

void main() {
  final set = SignalSet.parse(
      File('signalsets/Ford-F-150-Hybrid-2021/v01.json').readAsStringSync());
  late _Truck source;
  late List<CommandCheck> checks;

  setUp(() async {
    source = _Truck();
    await source.connect();
    checks = await SignalCheck.run(source, set);
  });

  CommandCheck check(String request) =>
      checks.singleWhere((c) => c.request == request);

  test('every request gets exactly one verdict, in signal-set order', () {
    expect([for (final c in checks) c.command], set.commands);
  });

  test('answered: raw reply and decoded values', () {
    final soc = check('224801');
    expect(soc.status, CheckStatus.answered);
    expect(soc.raw, '7EC 05 62 48 01 5A 3C');
    expect(soc.readings.single.signal.id, 'HVBAT_SOC');
    final v12 = check('224028');
    expect(v12.status, CheckStatus.answered);
    expect(v12.readings.single.value, 53);
  });

  test('rejected, silent and failed are told apart', () {
    final soh = check('22490C');
    expect(soh.status, CheckStatus.rejected);
    expect(soh.nrc, 0x31);
    expect(check('22480B').status, CheckStatus.silent);
    final bad = check('22480D');
    expect(bad.status, CheckStatus.failed);
    expect(bad.detail, 'CAN ERROR');
    expect({for (final c in checks) c.status}, CheckStatus.values.toSet());
  });

  test('a silent request is tried twice, the others once', () {
    int sent(String request) =>
        source.sentLog.where((c) => c == request).length;
    expect(sent('22480B'), 2);
    expect(sent('224801'), 1);
    expect(sent('22490C'), 1);
  });

  test('sets the addressing itself, whatever the adapter was left in', () {
    // Leaves extended addressing first (the BMW case), then header + filter.
    expect(
        source.sentLog,
        containsAllInOrder(
            ['ATCEA', 'ATSH7E4', 'ATCRA7EC', '224801', 'ATSH726', 'ATCRA72E']));
    // Nothing but the set's own read requests reaches the vehicle.
    final requests = {
      for (final c in source.sentLog)
        if (!c.startsWith('AT')) c
    };
    expect(
        requests, {for (final c in set.commands) '${c.service}${c.payload}'});
  });

  test('stops when asked', () async {
    final some = <CommandCheck>[];
    await SignalCheck.run(source, set,
        onResult: some.add, shouldStop: () => some.length == 3);
    expect(some, hasLength(3));
  });

  group('report', () {
    late String report;
    setUp(() async {
      report = SignalCheck.report(checks,
          set: set,
          when: DateTime(2026, 11, 16, 9, 5),
          adapter: 'Viecar',
          adapterInfo: await SignalCheck.adapterInfo(source));
    });

    test('says what was checked and how it went', () {
      final answered =
          checks.where((c) => c.status == CheckStatus.answered).length;
      final silent = checks.where((c) => c.status == CheckStatus.silent).length;
      expect(report, contains('# vehicle: ${set.vehicle}'));
      expect(report, contains('# when: 2026-11-16 09:05'));
      expect(report, contains('# adapter: Viecar  ATRV=12.4V  ATDPN=A6'));
      expect(
          report,
          contains('# answered $answered, rejected 1, silent $silent, '
              'failed 1 (of ${set.commands.length} requests)'));
      expect(report, contains('== 7E4 -> 7EC'));
      expect(
          report,
          contains(
              '224801  answered  7EC 05 62 48 01 5A 3C\n    HVBAT_SOC = '));
      expect(
          report,
          contains('22490C  rejected  7EC 03 7F 22 31  '
              '[31 requestOutOfRange]'));
      expect(report, contains('22480B  silent    NO DATA'));
      expect(report, contains('22480D  failed    CAN ERROR  [CAN ERROR]'));
      expect(report, contains('    LVBAT_SOC = 53 percent'));
    });

    test('its raw replies replay to the same values', () async {
      final replies = SignalCheck.repliesIn(report);
      expect(replies, hasLength(checks.length));
      expect([for (final r in replies) r.status],
          [for (final c in checks) c.status]);
      expect(replies.first.hdr, set.commands.first.hdr);
      expect(replies.first.rax, set.commands.first.rax);

      final replay =
          ReplaySource({for (final r in replies) r.request: r.response});
      await replay.connect();
      final again = await DiagnosticsClient(replay, set).readAll();
      final first = {
        for (final c in checks)
          for (final r in c.readings) r.signal.id: r.value
      };
      expect(first, isNotEmpty);
      expect({for (final e in again.entries) e.key: e.value.value}, first);
    });
  });

  test('BMW extended addressing: section carries the target address', () {
    final bmw = SignalSet.parse(
        File('signalsets/BMW-330e-2018/v02.json').readAsStringSync());
    final sme = bmw.commands.firstWhere((c) => c.eax == '07');
    final text = SignalCheck.report([
      const CommandCheck(Command(service: '01', payload: '0C', signals: []),
          CheckStatus.silent, 'NO DATA'),
      CommandCheck(sme, CheckStatus.silent, '')
    ], set: bmw, when: DateTime(2026));
    final replies = SignalCheck.repliesIn(text);
    expect(replies[0], (
      hdr: null,
      rax: null,
      eax: null,
      request: '010C',
      status: CheckStatus.silent,
      response: 'NO DATA\r>',
    ));
    expect(replies[1].hdr, sme.hdr);
    expect(replies[1].rax, sme.rax);
    expect(replies[1].eax, '07');
    expect(replies[1].response, '\r>');
  });
}
