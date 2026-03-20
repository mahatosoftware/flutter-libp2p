import 'package:flutter_libp2p/flutter_libp2p.dart';
import 'package:test/test.dart';

void main() {
  test('ed25519 peer ids are stable for a keypair', () async {
    final keyPair = await Libp2pKeyPair.generateEd25519();
    final peerIdA = PeerId.fromEd25519(keyPair);
    final peerIdB = PeerId.fromEd25519(keyPair);
    expect(peerIdA.toBase58(), peerIdB.toBase58());
  });
}
