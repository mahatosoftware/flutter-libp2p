import 'package:flutter_libp2p/flutter_libp2p.dart';
import 'package:test/test.dart';

void main() {
  test('peer store tracks connected peers', () async {
    final server = await Libp2pHost.create();
    final client = await Libp2pHost.create();

    addTearDown(server.close);
    addTearDown(client.close);

    final listenAddr = await server.listen(host: '127.0.0.1', port: 0);
    final connection = await client.connect(listenAddr);

    expect(client.peerStore.getPeer(connection.remotePeerId), isNotNull);
    expect(server.peerStore.getPeer(client.peerId), isNotNull);
  });

  test('kademlia can discover a peer through a connected node', () async {
    final bootstrap = await Libp2pHost.create();
    final seeker = await Libp2pHost.create();
    final target = await Libp2pHost.create();

    addTearDown(bootstrap.close);
    addTearDown(seeker.close);
    addTearDown(target.close);

    final bootstrapAddr = await bootstrap.listen(host: '127.0.0.1', port: 0);
    final targetAddr = await target.listen(host: '127.0.0.1', port: 0);

    await bootstrap.connect(targetAddr);
    await seeker.connect(bootstrapAddr);

    final found = await seeker.kadDht.findPeer(target.peerId);
    expect(found, isNotNull);
    expect(found!.peerId.toBase58(), target.peerId.toBase58());
    expect(found.addrs, isNotEmpty);
  });

  test('relay service returns a reservation', () async {
    final relay = await Libp2pHost.create();
    final client = await Libp2pHost.create();

    addTearDown(relay.close);
    addTearDown(client.close);

    final relayAddr = await relay.listen(host: '127.0.0.1', port: 0);
    final connection = await client.connect(relayAddr);
    final reservation = await client.relay.reserve(connection);

    expect(reservation.relayPeerId.toBase58(), relay.peerId.toBase58());
    expect(reservation.relayAddrs, isNotEmpty);
    expect(reservation.expiresAt.isAfter(DateTime.now()), isTrue);
  });
}
