/// Big-endian bit-field extraction + linear scaling for decoding OBD/UDS
/// response payloads into physical signal values.
///
/// A [SignalFormat] describes how to pull one numeric value out of a byte
/// payload: a big-endian bit field `[bix, bix+len)` is read, optionally
/// interpreted as two's-complement signed, then scaled `(raw * mul / div) + add`.
///
/// The payload passed to [decode] is the *data payload* — i.e. the response
/// bytes AFTER the service echo and the echoed identifier (2-byte DID for UDS
/// service 0x22, 1-byte PID for J1979 mode 01) have already been stripped.
/// Stripping is the responsibility of the protocol layer, not this module.
library;

class SignalFormat {
  final int bix;
  final int len;
  final bool sign;
  final num mul;
  final num div;
  final num add;
  final num? min;
  final num? max;
  final String? unit;

  const SignalFormat({
    this.bix = 0,
    required this.len,
    this.sign = false,
    this.mul = 1,
    this.div = 1,
    this.add = 0,
    this.min,
    this.max,
    this.unit,
  })  : assert(len > 0, 'len must be positive'),
        assert(len <= 64, 'len must be <= 64 bits'),
        assert(div != 0, 'div must be non-zero');

  factory SignalFormat.fromJson(Map<String, dynamic> j) => SignalFormat(
        bix: (j['bix'] as num?)?.toInt() ?? 0,
        len: (j['len'] as num).toInt(),
        sign: j['sign'] as bool? ?? false,
        mul: j['mul'] as num? ?? 1,
        div: j['div'] as num? ?? 1,
        add: j['add'] as num? ?? 0,
        min: j['min'] as num?,
        max: j['max'] as num?,
        unit: j['unit'] as String?,
      );

  /// Extract the raw (unscaled) integer field from [payload].
  ///
  /// Big-endian: bit 0 is the most-significant bit of `payload[0]`.
  /// Throws [RangeError] if the field extends past the end of [payload].
  int extractRaw(List<int> payload) {
    final endBit = bix + len;
    if (endBit > payload.length * 8) {
      throw RangeError(
        'Signal field [bit $bix, +$len) exceeds payload of '
        '${payload.length} bytes (${payload.length * 8} bits)',
      );
    }
    int value = 0;
    for (int i = 0; i < len; i++) {
      final bitIndex = bix + i;
      final byte = payload[bitIndex >> 3];
      final bit = (byte >> (7 - (bitIndex & 7))) & 1;
      value = (value << 1) | bit;
    }
    if (sign && len > 0) {
      // Two's-complement sign extension.
      final signBit = 1 << (len - 1);
      if ((value & signBit) != 0) {
        value -= (1 << len);
      }
    }
    return value;
  }

  /// Decode [payload] into the scaled physical value.
  double decode(List<int> payload) {
    final raw = extractRaw(payload);
    return (raw * mul / div) + add;
  }
}
