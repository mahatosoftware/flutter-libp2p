import 'dart:typed_data';

import '../address/multiaddr.dart';
import '../identity/peer_id.dart';
import 'peer_store_storage.dart';

class PeerRecord {
  PeerRecord(this.peerId);

  final PeerId peerId;
  final List<Multiaddr> addrs = <Multiaddr>[];
  final Set<String> protocols = <String>{};
  List<int>? publicKeyBytes;
  DateTime? firstSeenAt;
  DateTime? lastSeenAt;
  DateTime? connectedAt;
  DateTime? disconnectedAt;
  bool isConnected = false;

  void seenNow() {
    firstSeenAt ??= DateTime.now();
    lastSeenAt = DateTime.now();
  }

  void mergeAddrs(Iterable<Multiaddr> values) {
    for (final value in values) {
      if (addrs.any((existing) => existing.toString() == value.toString())) {
        continue;
      }
      addrs.add(value);
    }
    seenNow();
  }
}

class ContentProviderRecord {
  ContentProviderRecord({
    required this.peerId,
    required this.addrs,
    required this.expiresAt,
  });

  final PeerId peerId;
  final List<Multiaddr> addrs;
  final DateTime expiresAt;
}

class PeerStore {
  PeerStore({PeerStoreStorage? storage}) : _storage = storage ?? InMemoryPeerStorage();

  final PeerStoreStorage _storage;
  final Map<String, PeerRecord> _peers = <String, PeerRecord>{};
  final Map<String, List<ContentProviderRecord>> _providers =
      <String, List<ContentProviderRecord>>{};

  Future<void> init() async {
    final loaded = await _storage.loadPeers();
    for (final peer in loaded) {
      _peers[peer.peerId.toBase58()] = peer;
    }
  }

  // DHT KV Storage
  final Map<String, Uint8List> _values = <String, Uint8List>{};
  Uint8List? getValue(String key) => _values[key];
  void putValue(String key, Uint8List value) => _values[key] = value;

  Iterable<PeerRecord> get peers => _peers.values;

  PeerRecord upsertPeer(
    PeerId peerId, {
    Iterable<Multiaddr> addrs = const <Multiaddr>[],
    Iterable<String> protocols = const <String>[],
    List<int>? publicKeyBytes,
  }) {
    final key = peerId.toBase58();
    final record = _peers.putIfAbsent(key, () => PeerRecord(peerId));
    record.mergeAddrs(addrs);
    record.protocols.addAll(protocols);
    if (publicKeyBytes != null) {
      record.publicKeyBytes = List<int>.from(publicKeyBytes);
    }
    record.seenNow();
    _save();
    return record;
  }

  void _save() {
    _storage.savePeers(_peers.values.toList());
  }

  PeerRecord? getPeer(PeerId peerId) => _peers[peerId.toBase58()];

  PeerRecord? getPeerByBase58(String peerId) => _peers[peerId];

  void markConnected(PeerId peerId, Multiaddr remoteAddr) {
    final record = upsertPeer(peerId, addrs: <Multiaddr>[remoteAddr]);
    record.isConnected = true;
    record.connectedAt = DateTime.now();
    record.disconnectedAt = null;
  }

  void markDisconnected(PeerId peerId) {
    final record = getPeer(peerId);
    if (record == null) {
      return;
    }
    record.isConnected = false;
    record.disconnectedAt = DateTime.now();
    record.lastSeenAt = DateTime.now();
  }

  void addProvider(
    String key,
    PeerId peerId, {
    required Iterable<Multiaddr> addrs,
    Duration ttl = const Duration(hours: 24),
  }) {
    final record = ContentProviderRecord(
      peerId: peerId,
      addrs: List<Multiaddr>.from(addrs),
      expiresAt: DateTime.now().add(ttl),
    );
    final providers = _providers.putIfAbsent(
      key,
      () => <ContentProviderRecord>[],
    );
    providers.removeWhere((existing) => existing.peerId.toBase58() == peerId.toBase58());
    providers.add(record);
  }

  List<ContentProviderRecord> getProviders(String key) {
    final now = DateTime.now();
    final providers = _providers[key];
    if (providers == null) {
      return <ContentProviderRecord>[];
    }
    providers.removeWhere((provider) => provider.expiresAt.isBefore(now));
    return List<ContentProviderRecord>.from(providers);
  }
}
