import 'dart:typed_data';

Uint8List encodeUVarint(int value) {
  if (value < 0) {
    throw ArgumentError.value(value, 'value', 'must be non-negative');
  }

  final out = <int>[];
  var remaining = value;
  while (remaining >= 0x80) {
    out.add((remaining & 0x7f) | 0x80);
    remaining >>= 7;
  }
  out.add(remaining);
  return Uint8List.fromList(out);
}

class VarintDecodeResult {
  const VarintDecodeResult(this.value, this.length);

  final int value;
  final int length;
}

VarintDecodeResult decodeUVarint(List<int> bytes, [int offset = 0]) {
  var shift = 0;
  var value = 0;
  var index = offset;
  while (index < bytes.length) {
    final byte = bytes[index];
    value |= (byte & 0x7f) << shift;
    index++;
    if ((byte & 0x80) == 0) {
      return VarintDecodeResult(value, index - offset);
    }
    shift += 7;
    if (shift > 63) {
      throw const FormatException('varint is too long');
    }
  }
  throw const FormatException('incomplete varint');
}
