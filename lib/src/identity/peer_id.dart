import 'dart:typed_data';

import '../crypto/base58.dart';
import '../crypto/multihash.dart';
import '../crypto/protobuf.dart';
import 'keypair.dart';

enum KeyType {
  rsa(0),
  ed25519(1),
  secp256k1(2),
  ecdsa(3);

  const KeyType(this.code);

  final int code;
}

class PeerId {
  PeerId(this.multihashBytes);

  final Uint8List multihashBytes;

  String toBase58() => encodeBase58(multihashBytes);

  factory PeerId.fromBase58(String value) {
    return PeerId(decodeBase58(value));
  }

  @override
  String toString() => toBase58();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PeerId && _bytesEquals(multihashBytes, other.multihashBytes);

  @override
  int get hashCode => Object.hashAll(multihashBytes);

  bool _bytesEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
    }
    return true;
  }

  static Uint8List marshalPublicKey(KeyType type, Uint8List publicKeyBytes) {
    return Uint8List.fromList([
      ...protoEnum(1, type.code),
      ...protoBytes(2, publicKeyBytes),
    ]);
  }

  static PeerId fromPublicKey(KeyType type, Uint8List publicKeyBytes) {
    final marshaled = marshalPublicKey(type, publicKeyBytes);
    final multihash = marshaled.length <= 42
        ? multihashIdentity(marshaled)
        : multihashSha256(marshaled);
    return PeerId(multihash);
  }

  static PeerId fromEd25519(Libp2pKeyPair keyPair) {
    return fromPublicKey(KeyType.ed25519, keyPair.publicKeyBytes);
  }
}
