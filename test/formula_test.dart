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
}
