import 'package:obd_battery_diagnostics/transport/elm327_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('requestLine', () {
    test('formats message bytes as upper hex', () {
      expect(requestLine([0x22, 0xDD, 0xBC]), '22DDBC');
    });
    test('prepends BMW extended address', () {
      expect(requestLine([0x22, 0xDD, 0xBC], extendedAddress: 0x07),
          '0722DDBC');
    });
  });

  group('parseFrames (11-bit)', () {
    test('parses a single-line response with headers on', () {
      // 607 = SME response id, data 05 62 DD BC 03 20
      final frames = parseFrames('60705 62 DD BC 03 20\r\r>', is29Bit: false);
      expect(frames, hasLength(1));
      expect(frames.single.canId, '607');
      expect(frames.single.data, [0x05, 0x62, 0xDD, 0xBC, 0x03, 0x20]);
    });

    test('parses a multi-line ISO-TP response', () {
      final raw = '607 10 14 62 DF A0 0F 00\r'
          '607 21 0F 10 0F 08 00 00\r'
          '>';
      final frames = parseFrames(raw, is29Bit: false);
      expect(frames, hasLength(2));
      expect(frames[0].data.first, 0x10); // first frame PCI
      expect(frames[1].data.first, 0x21); // consecutive frame PCI
    });

    test('throws on NO DATA', () {
      expect(() => parseFrames('NO DATA\r>', is29Bit: false),
          throwsA(isA<ElmException>()));
    });

    test('throws on CAN ERROR', () {
      expect(() => parseFrames('CAN ERROR\r>', is29Bit: false),
          throwsA(isA<ElmException>()));
    });
  });

  group('parseFrames (29-bit)', () {
    test('uses an 8-nibble header width', () {
      // 18DAF110 is a typical 29-bit diagnostic response id.
      final frames =
          parseFrames('18DAF110 03 41 0D 20\r>', is29Bit: true);
      expect(frames.single.canId, '18DAF110');
      expect(frames.single.data, [0x03, 0x41, 0x0D, 0x20]);
    });
  });
}
