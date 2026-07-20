/// ISO-TP (ISO 15765-2) frame parsing and multi-frame reassembly.
///
/// Works on the *data field* of CAN frames (the up-to-8 payload bytes, or more
/// for CAN-FD). It handles the four PCI frame types:
///   - Single Frame (SF)      : 0x0L ...            (L = length, 0..7)
///   - First Frame (FF)       : 0x1L LL ...         (12-bit length)
///   - Consecutive Frame (CF) : 0x2N ...            (N = sequence 0..15, wraps)
///   - Flow Control (FC)      : 0x3S BS STmin       (S = flow status)
///
/// Addressing width (11- vs 29-bit) does not change this data-field layout; it
/// only affects the CAN id, which the transport layer deals with. Escape-length
/// SF (0x00 <len>) is supported for CAN-FD payloads > 7 bytes.
library;

enum IsoTpFrameType { single, first, consecutive, flowControl, unknown }

IsoTpFrameType frameTypeOf(List<int> dataField) {
  if (dataField.isEmpty) return IsoTpFrameType.unknown;
  switch (dataField[0] >> 4) {
    case 0x0:
      return IsoTpFrameType.single;
    case 0x1:
      return IsoTpFrameType.first;
    case 0x2:
      return IsoTpFrameType.consecutive;
    case 0x3:
      return IsoTpFrameType.flowControl;
    default:
      return IsoTpFrameType.unknown;
  }
}

/// Flow-control the tester should send after a First Frame:
/// FlowStatus=Continue(0), BlockSize=0 (send all), STmin=0 (no delay).
const List<int> defaultFlowControlFrame = [0x30, 0x00, 0x00];

/// Reassembles a complete ISO-TP message from an ordered stream of CAN data
/// fields belonging to a single response. Feed frames with [addFrame] until it
/// returns the completed message (non-null), or use [reassemble] for a full list.
class IsoTpReassembler {
  int? _expectedLength;
  final List<int> _buffer = [];
  int _nextSeq = 1;
  bool _started = false;

  bool get isComplete =>
      _expectedLength != null && _buffer.length >= _expectedLength!;

  /// Add one CAN data field. Returns the completed message once fully received,
  /// otherwise null. Throws [FormatException] on protocol violations.
  List<int>? addFrame(List<int> dataField) {
    if (dataField.isEmpty) {
      throw const FormatException('Empty ISO-TP frame');
    }
    final type = frameTypeOf(dataField);
    switch (type) {
      case IsoTpFrameType.single:
        int len = dataField[0] & 0x0F;
        int dataStart = 1;
        if (len == 0) {
          // CAN-FD escape length: 0x00 <length>.
          if (dataField.length < 2) {
            throw const FormatException('Truncated escape-length single frame');
          }
          len = dataField[1];
          dataStart = 2;
        }
        _expectedLength = len;
        _buffer
          ..clear()
          ..addAll(dataField.sublist(dataStart, dataStart + len));
        _started = true;
        return List<int>.unmodifiable(_buffer);

      case IsoTpFrameType.first:
        if (dataField.length < 2) {
          throw const FormatException('Truncated first frame');
        }
        _expectedLength = ((dataField[0] & 0x0F) << 8) | dataField[1];
        _buffer
          ..clear()
          ..addAll(dataField.sublist(2));
        _nextSeq = 1;
        _started = true;
        return isComplete ? List<int>.unmodifiable(_buffer) : null;

      case IsoTpFrameType.consecutive:
        if (!_started || _expectedLength == null) {
          throw const FormatException(
              'Consecutive frame before first frame');
        }
        final seq = dataField[0] & 0x0F;
        if (seq != _nextSeq) {
          throw FormatException(
              'ISO-TP sequence gap: expected $_nextSeq, got $seq');
        }
        _nextSeq = (_nextSeq + 1) & 0x0F;
        final remaining = _expectedLength! - _buffer.length;
        final take = remaining < (dataField.length - 1)
            ? remaining
            : (dataField.length - 1);
        _buffer.addAll(dataField.sublist(1, 1 + take));
        return isComplete ? List<int>.unmodifiable(_buffer) : null;

      case IsoTpFrameType.flowControl:
        // Flow control frames are sent by the receiver, not part of the data;
        // ignore if encountered in an inbound stream.
        return null;

      case IsoTpFrameType.unknown:
        throw FormatException(
            'Unknown ISO-TP PCI 0x${dataField[0].toRadixString(16)}');
    }
  }

  void reset() {
    _expectedLength = null;
    _buffer.clear();
    _nextSeq = 1;
    _started = false;
  }
}

/// Convenience: reassemble a complete message from an ordered list of CAN data
/// fields (single frame, or FF followed by CFs). Flow-control frames are ignored.
List<int> reassemble(Iterable<List<int>> frames) {
  final r = IsoTpReassembler();
  List<int>? result;
  for (final f in frames) {
    result = r.addFrame(f);
  }
  if (result == null || !r.isComplete) {
    throw const FormatException('Incomplete ISO-TP message');
  }
  return result;
}
