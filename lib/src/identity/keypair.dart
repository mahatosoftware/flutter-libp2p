import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
class Libp2pKeyPair {
  Libp2pKeyPair._(this._keyPair, this.publicKeyBytes);

  final SimpleKeyPair _keyPair;
  final Uint8List publicKeyBytes;

  static final Ed25519 _algorithm = Ed25519();

  static Future<Libp2pKeyPair> generateEd25519() async {
    final keyPair = await _algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    return Libp2pKeyPair._(keyPair, Uint8List.fromList(publicKey.bytes));
  }

  SimpleKeyPair get rawKeyPair => _keyPair;

  Future<Uint8List> sign(List<int> message) async {
    final signature = await _algorithm.sign(
      message,
      keyPair: _keyPair,
    );
    return Uint8List.fromList(signature.bytes);
  }

  static Future<bool> verifyEd25519({
    required List<int> message,
    required List<int> signatureBytes,
    required List<int> publicKeyBytes,
  }) {
    return _algorithm.verify(
      message,
      signature: Signature(
        signatureBytes,
        publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
      ),
    );
  }
}
