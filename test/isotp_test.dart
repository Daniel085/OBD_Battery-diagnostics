import 'package:obd_battery_diagnostics/protocol/isotp.dart';
import 'package:test/test.dart';

void main() {
  group('frameTypeOf', () {
    test('classifies PCI types', () {
      expect(frameTypeOf([0x03, 1, 2, 3]), IsoTpFrameType.single);
      expect(frameTypeOf([0x10, 0x14]), IsoTpFrameType.first);
      expect(frameTypeOf([0x21, 1, 2]), IsoTpFrameType.consecutive);
      expect(frameTypeOf([0x30, 0, 0]), IsoTpFrameType.flowControl);
    });
  });

  group('single frame', () {
    test('reassembles a short message', () {
      // SF, length 3, data 62 DD BC (UDS 0x22 response to DID DDBC)
      final msg = reassemble([
        [0x03, 0x62, 0xDD, 0xBC, 0x00, 0x00, 0x00, 0x00],
      ]);
      expect(msg, [0x62, 0xDD, 0xBC]);
    });

    test('escape-length single frame (CAN-FD)', () {
      final data = [0x00, 0x09, 1, 2, 3, 4, 5, 6, 7, 8, 9];
      expect(reassemble([data]), [1, 2, 3, 4, 5, 6, 7, 8, 9]);
    });
  });

  group('multi-frame', () {
    test('reassembles FF + CFs to exact declared length', () {
      // Declared length 0x014 = 20 bytes.
      // FF carries 6 data bytes, each CF up to 7.
      final ff = [0x10, 0x14, 1, 2, 3, 4, 5, 6]; // 6 bytes
      final cf1 = [0x21, 7, 8, 9, 10, 11, 12, 13]; // +7 = 13
      final cf2 = [0x22, 14, 15, 16, 17, 18, 19, 20]; // +7 = 20
      final msg = reassemble([ff, cf1, cf2]);
      expect(msg.length, 20);
      expect(msg, List.generate(20, (i) => i + 1));
    });

    test('trims padding on the last consecutive frame', () {
      // Declared 0x00A = 10 bytes: FF gives 6, one CF needs 4 more (padded).
      final ff = [0x10, 0x0A, 1, 2, 3, 4, 5, 6];
      final cf1 = [0x21, 7, 8, 9, 10, 0xAA, 0xAA, 0xAA]; // last 3 are padding
      final msg = reassemble([ff, cf1]);
      expect(msg, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    });

    test('detects a sequence gap', () {
      final r = IsoTpReassembler();
      r.addFrame([0x10, 0x14, 1, 2, 3, 4, 5, 6]);
      expect(
        () => r.addFrame([0x22, 7, 8, 9, 10, 11, 12, 13]), // expected seq 1
        throwsFormatException,
      );
    });

    test('rejects a consecutive frame with no first frame', () {
      final r = IsoTpReassembler();
      expect(() => r.addFrame([0x21, 1, 2, 3]), throwsFormatException);
    });
  });
}
