import 'dart:convert';
import 'dart:typed_data';

import 'varint.dart';

Uint8List protoKey(int fieldNumber, int wireType) {
  return encodeUVarint((fieldNumber << 3) | wireType);
}

Uint8List protoBytes(int fieldNumber, List<int> value) {
  return Uint8List.fromList([
    ...protoKey(fieldNumber, 2),
    ...encodeUVarint(value.length),
    ...value,
  ]);
}

Uint8List protoString(int fieldNumber, String value) {
  return protoBytes(fieldNumber, utf8.encode(value));
}

Uint8List protoEnum(int fieldNumber, int value) {
  return Uint8List.fromList([
    ...protoKey(fieldNumber, 0),
    ...encodeUVarint(value),
  ]);
}
