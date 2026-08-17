/// CapacityTestSession: synthetic scenarios + validation against the real
/// 2026-08-15 Lyriq charge log (captures/2026-08-14-capacity-hunt/chglog.txt).
///
/// Ground-truth figures for the fixture were computed with an independent
/// Python implementation of the same policy:
///   segment 1: 35 samples 09:14:24–09:51:26, −14.073 Ah, ended by observed
///              0 A samples at 09:52:29+ (the known 09:52 charge cutoff);
///   segment 2: 66 samples 10:12:02–11:22:19, −26.111 Ah (log ends mid-charge);
///   total 40.184 Ah charged.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obd_battery_diagnostics/engine/capacity_test.dart';

DateTime t0 = DateTime.utc(2026, 8, 15, 8);
DateTime at(int minutes, [int seconds = 0]) =>
    t0.add(Duration(minutes: minutes, seconds: seconds));

void main() {
  group('synthetic sessions', () {
    test('steady charge integrates to I×t', () {
      final s = CapacityTestSession(startedAt: t0);
      for (var m = 0; m <= 60; m += 5) {
        s.addSample(at(m), -20.0);
      }
      final a = s.analyze();
      expect(a.segments, hasLength(1));
      expect(a.chargedAh, closeTo(20.0, 0.001)); // 20 A × 1 h
      expect(a.chargedKwh, closeTo(20 * 352.1 / 1000, 0.01));
      expect(a.coverage, closeTo(1.0, 0.001));
      expect(a.chargingNow, isTrue);
      expect(a.errAh, lessThan(0.5)); // jitter 0; small leading-edge term
    });

    test('hours-long gap between charging samples is interpolated, not split',
        () {
      final s = CapacityTestSession(startedAt: t0);
      // Connected burst, 3 h disconnected, connected burst — one charge.
      for (var m = 0; m <= 10; m += 5) {
        s.addSample(at(m), -20.0);
      }
      for (var m = 190; m <= 200; m += 5) {
        s.addSample(at(m), -20.0);
      }
      final a = s.analyze();
      expect(a.segments, hasLength(1));
      expect(a.chargedAh, closeTo(20.0 * 200 / 60, 0.01)); // full window
      expect(a.largestGap, const Duration(minutes: 180));
      // 20 min good + 5-min credit for the gap, over 200 min charging.
      expect(a.coverage, closeTo(25 / 200, 0.01));
    });

    test('observed idle sample splits segments and bounds their edges', () {
      final s = CapacityTestSession(startedAt: t0);
      for (var m = 0; m <= 30; m += 5) {
        s.addSample(at(m), -20.0);
      }
      s.addSample(at(35), 0.0); // charger off, seen
      for (var m = 60; m <= 90; m += 5) {
        s.addSample(at(m), -20.0);
      }
      final a = s.analyze();
      expect(a.segments, hasLength(2));
      expect(a.chargedAh, closeTo(20.0, 0.001)); // 2 × (20 A × 0.5 h)
      // Edge terms: seg1 lead 0 (bounded by session start = first sample),
      // seg1 trail ½·20·(5/60) to the observed idle sample, seg2 lead
      // ½·20·(25/60) from it, seg2 trail 0 (open, still charging).
      expect(a.errAh, closeTo(20 * (5 + 25) / 60 / 2, 0.01));
    });

    test('idle noise below threshold never starts a segment', () {
      final s = CapacityTestSession(startedAt: t0);
      for (var m = 0; m <= 60; m += 5) {
        s.addSample(at(m), m.isEven ? 0.9 : -1.2); // Ready-mode jitter
      }
      final a = s.analyze();
      expect(a.segments, isEmpty);
      expect(a.chargedAh, 0);
      expect(a.chargingNow, isFalse);
    });

    test('SOC endpoints extrapolate pack capacity and SOH', () {
      final s = CapacityTestSession(startedAt: t0)
        ..socStartPct = 70
        ..socEndPct = 80;
      // The real measurement: 29.2 Ah over exactly 10%.
      for (var m = 0; m <= 77; m += 1) {
        s.addSample(at(m), -22.75);
      }
      final a = s.analyze();
      expect(a.chargedAh, closeTo(22.75 * 77 / 60, 0.01)); // ≈29.2
      expect(a.packAh, closeTo(a.chargedAh * 10, 0.1)); // ≈292
      expect(a.packKwh, closeTo(a.packAh! * 352.1 / 1000, 0.1)); // ≈103
      expect(a.sohPct, closeTo(a.packKwh! / 102 * 100, 0.1)); // ≈100.8
    });

    test('no SOH until both endpoints present and ordered', () {
      final s = CapacityTestSession(startedAt: t0);
      s.addSample(at(0), -20);
      s.addSample(at(30), -20);
      expect(s.analyze().sohPct, isNull);
      s.socStartPct = 80;
      s.socEndPct = 70; // reversed → invalid
      expect(s.analyze().sohPct, isNull);
    });

    test('JSON round-trip preserves the analysis', () {
      final s = CapacityTestSession(startedAt: t0)
        ..socStartPct = 56
        ..socEndPct = 70;
      for (var m = 0; m <= 45; m += 3) {
        s.addSample(at(m), -22.0 + (m % 2));
      }
      s.finish(at: at(50));
      final restored =
          CapacityTestSession.fromJsonString(s.toJsonString());
      expect(restored.isFinished, isTrue);
      expect(restored.samples.length, s.samples.length);
      expect(restored.analyze().chargedAh, closeTo(s.analyze().chargedAh, 1e-9));
      expect(restored.socEndPct, 70);
      // Restored-finished sessions refuse further samples.
      restored.addSample(at(60), -22);
      expect(restored.samples.length, s.samples.length);
    });

    test('out-of-order samples are inserted, not appended', () {
      final s = CapacityTestSession(startedAt: t0);
      s.addSample(at(10), -20);
      s.addSample(at(0), -20);
      s.addSample(at(5), -20);
      expect(s.samples.map((x) => x.t).toList(),
          [at(0), at(5), at(10)]);
      expect(s.analyze().chargedAh, closeTo(20 * 10 / 60, 1e-6));
    });
  });

  group('real Lyriq charge log (chglog.txt)', () {
    test('reproduces the hand-verified session figures', () {
      final samples = parseChgLog(
          File('captures/2026-08-14-capacity-hunt/chglog.txt')
              .readAsStringSync());
      expect(samples, hasLength(104));

      final s = CapacityTestSession(startedAt: samples.first.t);
      for (final c in samples) {
        s.addSample(c.t, c.amps);
      }
      final a = s.analyze();

      // Two sessions: cutoff at 09:52 (observed 0 A), then the 70→80% charge.
      expect(a.segments, hasLength(2));
      expect(a.segments[0].sampleCount, 35);
      expect(a.segments[1].sampleCount, 66);
      expect(a.segments[0].ah, closeTo(14.073, 0.01));
      expect(a.segments[1].ah, closeTo(26.111, 0.01));
      expect(a.chargedAh, closeTo(40.184, 0.02));
      expect(a.segments[0].meanAmps, closeTo(-22.79, 0.05));
      // Steady current → tiny jitter error; edges dominated by the bounded
      // 09:51:26→09:52:29 stop and the unbounded-by-idle 10:12 restart.
      expect(a.errAh, lessThan(4.0));
      expect(a.coverage, closeTo(1.0, 0.01)); // 2.5-min sampling throughout
      expect(a.chargingNow, isTrue); // log ends mid-charge

      // The known result, using the observed segment-1 cutoff at ~09:52 and
      // dash 59→70%: capacity comes out near rated.
      final s1 = CapacityTestSession(startedAt: samples.first.t)
        ..socStartPct = 70
        ..socEndPct = 80;
      // Session 2 only: drop everything before the 09:54 idle marker.
      for (final c in samples.where(
          (c) => c.t.isAfter(DateTime.utc(2026, 8, 15, 9, 55)))) {
        s1.addSample(c.t, c.amps);
      }
      final a1 = s1.analyze();
      // Log ends before the 80% cutoff, so this bounds capacity from below:
      // 26.1 Ah of the eventual ~29.2 Ah captured.
      expect(a1.packAh, closeTo(261.1, 1.0));
    });
  });
}

/// Parse the Pi logger format: `HH:MM:SS 17.2414=<raw response hex> ...`
/// lines, `=== logger start YYYY-MM-DD HH:MM:SS` headers carrying the date,
/// midnight rollover, and dropout markers (`DAA`/`CAE`) to be skipped.
/// Response format: 18DAF117 05 62 2414 <s16>, amps = s16/20.
List<CurrentSample> parseChgLog(String text) {
  final out = <CurrentSample>[];
  DateTime? prev;
  var date = DateTime.utc(2026, 8, 14);
  final header = RegExp(r'^=== logger start (\d{4})-(\d{2})-(\d{2})');
  final line = RegExp(r'^(\d\d):(\d\d):(\d\d) ');
  final did = RegExp(r'17\.2414=(18DAF117[0-9A-Fa-f]+)');
  for (final ln in text.split('\n')) {
    final h = header.firstMatch(ln);
    if (h != null) {
      date = DateTime.utc(int.parse(h.group(1)!), int.parse(h.group(2)!),
          int.parse(h.group(3)!));
      continue;
    }
    final m = line.firstMatch(ln);
    if (m == null) continue;
    var t = DateTime.utc(date.year, date.month, date.day,
        int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
    if (prev != null && t.isBefore(prev)) {
      date = date.add(const Duration(days: 1));
      t = t.add(const Duration(days: 1));
    }
    prev = t;
    final d = did.firstMatch(ln);
    if (d == null) continue;
    final hex = d.group(1)!;
    var raw = int.parse(hex.substring(hex.length - 4), radix: 16);
    if (raw >= 0x8000) raw -= 0x10000;
    out.add(CurrentSample(t, raw / 20.0));
  }
  return out;
}
