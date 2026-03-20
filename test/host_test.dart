import 'package:flutter_libp2p/flutter_libp2p.dart';
import 'package:test/test.dart';

void main() {
  test('two hosts can connect, ping, and identify', () async {
    final server = await Libp2pHost.create();
    final client = await Libp2pHost.create();

    addTearDown(server.close);
    addTearDown(client.close);

    final listenAddr = await server.listen(host: '127.0.0.1', port: 0);
    final connection = await client.connect(listenAddr);

    final latency = await client.ping(connection);
    expect(latency, isA<Duration>());

    final identify = await client.identify(connection);
    expect(identify.agentVersion, contains('flutter-libp2p'));
    expect(identify.protocols, contains(PingProtocol.protocolId));
    expect(identify.listenAddrs, isNotEmpty);
  });
}
