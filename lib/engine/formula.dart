/// Bit-field extraction (big-endian unless a field says otherwise) + linear
/// scaling for decoding OBD/UDS response payloads into physical signal values.
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

  /// Little-endian byte order: the field's bytes are taken last-first. Only
  /// for whole bytes (`bix` and `len` multiples of 8). Default is big-endian.
  final bool le;
  final num mul;
  final num div;
  final num add;
  final num? min;
  final num? max;

  /// Physical values at or below [nullmin] / at or above [nullmax] mean "no
  /// value" (e.g. a raw 0 sentinel), as in the OBDb v3 schema.
  final num? nullmin;
  final num? nullmax;
  final String? unit;

  /// Names for particular decoded values (OBDb `map`), e.g. `{0: 'OK'}`.
  /// A value with a name is shown as that name instead of a number.
  final Map<num, String> labels;

  const SignalFormat({
    this.bix = 0,
    required this.len,
    this.sign = false,
    this.le = false,
    this.mul = 1,
    this.div = 1,
    this.add = 0,
    this.min,
    this.max,
    this.nullmin,
    this.nullmax,
    this.unit,
    this.labels = const {},
  })  : assert(len > 0, 'len must be positive'),
        assert(len <= 64, 'len must be <= 64 bits'),
        assert(div != 0, 'div must be non-zero'),
        assert(!le || (bix % 8 == 0 && len % 8 == 0),
            'a little-endian field must cover whole bytes');

  factory SignalFormat.fromJson(Map<String, dynamic> j) => SignalFormat(
        bix: (j['bix'] as num?)?.toInt() ?? 0,
        len: (j['len'] as num).toInt(),
        sign: j['sign'] as bool? ?? false,
        le: j['le'] as bool? ?? false,
        mul: j['mul'] as num? ?? 1,
        div: j['div'] as num? ?? 1,
        add: j['add'] as num? ?? 0,
        min: j['min'] as num?,
        max: j['max'] as num?,
        nullmin: j['nullmin'] as num?,
        nullmax: j['nullmax'] as num?,
        unit: j['unit'] as String?,
        labels: {
          for (final e
              in (j['map'] as Map<String, dynamic>? ?? const {}).entries)
            num.parse(e.key): switch (e.value) {
              final String s => s,
              final Map<String, dynamic> m => m['value'] as String,
              _ => throw FormatException('Bad map entry for ${e.key}'),
            },
        },
      );

  /// The name the signal set gives [value], or null when it has none.
  String? labelFor(double value) => labels[value] ?? labels[value.round()];

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
    if (le) {
      if (bix % 8 != 0 || len % 8 != 0) {
        throw ArgumentError(
            'A little-endian field must cover whole bytes (bix $bix, len $len)');
      }
      for (int i = endBit ~/ 8 - 1; i >= bix ~/ 8; i--) {
        value = (value << 8) | (payload[i] & 0xFF);
      }
    } else {
      for (int i = 0; i < len; i++) {
        final bitIndex = bix + i;
        final byte = payload[bitIndex >> 3];
        final bit = (byte >> (7 - (bitIndex & 7))) & 1;
        value = (value << 1) | bit;
      }
    }
    if (sign && len > 0 && len < 64) {
      // Two's-complement sign extension. Guarded to len < 64 because `1 << 64`
      // wraps to 0 on Dart's 64-bit int, which would silently skip extension.
      // A full 64-bit signed field is already correctly signed in a Dart int,
      // so no adjustment is needed there.
      final signBit = 1 << (len - 1);
      if ((value & signBit) != 0) {
        value -= (1 << len);
      }
    }
    return value;
  }

  /// Decode [payload] into the scaled physical value. Ignores the null
  /// bounds; readers that should drop "no value" replies use [decodeOrNull].
  double decode(List<int> payload) {
    final raw = extractRaw(payload);
    return (raw * mul / div) + add;
  }

  /// True when [value] falls on or past a null bound.
  bool isNull(double value) =>
      (nullmin != null && value <= nullmin!) ||
      (nullmax != null && value >= nullmax!);

  /// Like [decode], but null when the value is on or past a null bound.
  double? decodeOrNull(List<int> payload) {
    final v = decode(payload);
    return isNull(v) ? null : v;
  }
}
