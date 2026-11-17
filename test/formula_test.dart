import 'package:obd_battery_diagnostics/engine/formula.dart';
import 'package:test/test.dart';

void main() {
  group('SignalFormat.extractRaw', () {
    test('reads a byte-aligned 8-bit field', () {
      const f = SignalFormat(bix: 0, len: 8);
      expect(f.extractRaw([0x64]), 0x64); // 100
    });

    test('reads a 16-bit big-endian field', () {
      const f = SignalFormat(bix: 0, len: 16);
      expect(f.extractRaw([0x12, 0x34]), 0x1234);
    });

    test('reads a field at a non-zero bit offset', () {
      const f = SignalFormat(bix: 16, len: 16);
      expect(f.extractRaw([0xAA, 0xBB, 0x12, 0x34]), 0x1234);
    });

    test('reads a sub-byte field', () {
      // 0b1010_1010 -> top 4 bits = 0b1010 = 10
      const f = SignalFormat(bix: 0, len: 4);
      expect(f.extractRaw([0xAA]), 0x0A);
    });

    test('sign extends two-s-complement negatives', () {
      const f = SignalFormat(bix: 0, len: 16, sign: true);
      // 0xFFFF = -1
      expect(f.extractRaw([0xFF, 0xFF]), -1);
      // 0x8000 = -32768
      expect(f.extractRaw([0x80, 0x00]), -32768);
    });

    test('throws when the field runs past the payload', () {
      const f = SignalFormat(bix: 0, len: 16);
      expect(() => f.extractRaw([0x12]), throwsRangeError);
    });

    test('64-bit signed field is not corrupted by 1<<64 wraparound', () {
      const f = SignalFormat(bix: 0, len: 64, sign: true);
      // 0x7FFF... (max positive) stays positive.
      expect(f.extractRaw([0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
          0x7FFFFFFFFFFFFFFF);
      // All-ones reads as -1 in a native 64-bit int (already correct).
      expect(f.extractRaw([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]), -1);
    });
  });

  group('SignalFormat little-endian fields', () {
    test('whole bytes are read last-first', () {
      // BMW 330e SME DD73 on 2026-11-15: 08 5C 4E 07 = 0x074E5C08 A*s.
      const f = SignalFormat(len: 32, le: true, div: 3600);
      expect(f.extractRaw([0x08, 0x5C, 0x4E, 0x07]), 0x074E5C08);
      expect(f.decode([0x08, 0x5C, 0x4E, 0x07]), closeTo(34048.86, 0.01));
    });

    test('offset, sign and JSON', () {
      final f = SignalFormat.fromJson(
          {'bix': 8, 'len': 16, 'le': true, 'sign': true});
      expect(f.extractRaw([0xAA, 0xFE, 0xFF, 0xBB]), -2);
      expect(SignalFormat.fromJson({'len': 16}).le, isFalse);
    });

    test('a field that is not whole bytes is refused', () {
      expect(
          () => SignalFormat.fromJson({'bix': 4, 'len': 12, 'le': true})
              .extractRaw([0, 0]),
          throwsA(anything));
    });
  });

  group('SignalFormat value names (OBDb map)', () {
    test('plain strings and OBDb objects', () {
      final f = SignalFormat.fromJson({
        'len': 8,
        'map': {
          '0': {'value': 'OK', 'description': 'no defect'},
          '1': 'Fault',
        },
      });
      expect(f.labelFor(0), 'OK');
      expect(f.labelFor(1), 'Fault');
      expect(f.labelFor(2), isNull);
      expect(const SignalFormat(len: 8).labelFor(0), isNull);
    });
  });

  group('SignalFormat.decode (scaling)', () {
    test('applies div', () {
      // SOC: raw/10 -> percent. 0x0320 = 800 -> 80.0
      const f = SignalFormat(bix: 0, len: 16, div: 10);
      expect(f.decode([0x03, 0x20]), closeTo(80.0, 1e-9));
    });

    test('applies div for cell voltage 1/10000 V', () {
      // 0x0F00 = 3840 -> 0.3840? No: div 10000 -> 3840/10000 = 0.384
      const f = SignalFormat(bix: 0, len: 16, div: 10000);
      expect(f.decode([0x0F, 0x00]), closeTo(0.384, 1e-9));
    });

    test('applies signed + div for current', () {
      // -1 raw / 100 = -0.01 A
      const f = SignalFormat(bix: 0, len: 32, sign: true, div: 100);
      expect(f.decode([0xFF, 0xFF, 0xFF, 0xFF]), closeTo(-0.01, 1e-9));
    });

    test('applies mul, div and add together', () {
      const f = SignalFormat(bix: 0, len: 8, mul: 2, div: 4, add: 10);
      // raw 8 * 2 / 4 + 10 = 14
      expect(f.decode([0x08]), closeTo(14.0, 1e-9));
    });
  });

  group('SignalFormat null bounds (OBDb nullmin/nullmax)', () {
    test('a value at or past a bound decodes to null', () {
      const lo = SignalFormat(len: 8, add: -40, nullmin: -40);
      expect(lo.decodeOrNull([0x00]), isNull); // raw 0 -> -40 -> no value
      expect(lo.decodeOrNull([0x46]), closeTo(30, 1e-9));
      const hi = SignalFormat(len: 8, nullmax: 255);
      expect(hi.decodeOrNull([0xFF]), isNull);
      expect(hi.decodeOrNull([0xFE]), 254);
    });

    test('no bounds -> unchanged; decode() ignores bounds', () {
      const f = SignalFormat(len: 8);
      expect(f.decodeOrNull([0x00]), 0);
      const lo = SignalFormat(len: 8, add: -40, nullmin: -40);
      expect(lo.decode([0x00]), -40);
    });

    test('parsed from JSON', () {
      final f = SignalFormat.fromJson(
          {'len': 8, 'add': -40, 'nullmin': -40, 'nullmax': 200});
      expect(f.nullmin, -40);
      expect(f.nullmax, 200);
    });
  });
}
