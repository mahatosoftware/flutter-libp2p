import 'package:flutter_libp2p/src/host/host.dart';
import 'package:flutter_libp2p/src/address/multiaddr.dart';
import 'package:test/test.dart';
import '../mock_transport.dart';

void main() {
  group('In-memory DHT Network (20 nodes)', () {
    test('Nodes should bootstrap and find each other', () async {
      final transport = MockTcpTransport();
      final hosts = <Libp2pHost>[];
      
      // Create 20 nodes
      for (var i = 1; i <= 20; i++) {
        final host = await Libp2pHost.create(transport: transport);
        await host.listen(port: i);
        hosts.add(host);
      }
      
      // Bootstrap line-style: each node connects to the previous one
      for (var i = 1; i < hosts.length; i++) {
        await hosts[i].kadDht.bootstrap([hosts[i-1].listenAddrs.first]);
      }
      
      // Node 20 should be able to find Node 1 through 19 hops maybe?
      // Kademlia should optimize this.
      final target = hosts[0];
      final searcher = hosts[19];
      
      final record = await searcher.kadDht.findPeer(target.peerId);
      expect(record, isNotNull);
      expect(record!.peerId, equals(target.peerId));
      
      // Verify providers
      final testKey = 'test-resource';
      await hosts[0].kadDht.addProvider(testKey, hosts[0].peerId, hosts[0].listenAddrs);
      
      final providers = await hosts[19].kadDht.findProviders(testKey);
      expect(providers, isNotEmpty);
      expect(providers.any((p) => p.peerId == hosts[0].peerId), isTrue);
      
      // Clean up
      for (final host in hosts) {
        await host.close();
      }
    });
  });
}
