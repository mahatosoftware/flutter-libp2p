import 'dart:convert';
import '../address/multiaddr.dart';
import '../identity/peer_id.dart';
import 'peer_store.dart';

abstract class PeerStoreStorage {
  Future<void> savePeers(List<PeerRecord> peers);
  Future<List<PeerRecord>> loadPeers();
}

class InMemoryPeerStorage implements PeerStoreStorage {
  @override
  Future<List<PeerRecord>> loadPeers() async => [];
  @override
  Future<void> savePeers(List<PeerRecord> peers) async {}
}
