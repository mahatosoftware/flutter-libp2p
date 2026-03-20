import 'package:flutter_libp2p/flutter_libp2p.dart';
import 'package:test/test.dart';

void main() {
  test('multiaddr round trips through binary encoding', () {
    final original = Multiaddr.parse(
      '/ip4/127.0.0.1/tcp/4001/p2p/12D3KooWJ5Jv',
    );
    final encoded = original.toBytes();
    final decoded = Multiaddr.fromBytes(encoded);
    expect(decoded.toString(), original.toString());
  });
}
