import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'varint.dart';

const identityMultihashCode = 0x00;
const sha256MultihashCode = 0x12;

Uint8List multihashIdentity(Uint8List bytes) {
  return Uint8List.fromList([
    ...encodeUVarint(identityMultihashCode),
    ...encodeUVarint(bytes.length),
    ...bytes,
  ]);
}

Uint8List multihashSha256(Uint8List bytes) {
  final digest = crypto.sha256.convert(bytes).bytes;
  return Uint8List.fromList([
    ...encodeUVarint(sha256MultihashCode),
    ...encodeUVarint(digest.length),
    ...digest,
  ]);
}
