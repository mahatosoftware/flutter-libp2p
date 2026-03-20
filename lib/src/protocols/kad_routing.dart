import 'dart:typed_data';

import '../identity/peer_id.dart';

class RoutingTable {
  RoutingTable(this.localPeerId, {this.k = 20});

  final PeerId localPeerId;
  final int k;
  final List<KBucket> _buckets = <KBucket>[];

  void addPeer(PeerId peerId) {
    if (peerId == localPeerId) return;

    final distance = xorDistance(localPeerId.multihashBytes, peerId.multihashBytes);
    final bucketIndex = _bucketIndex(distance);

    while (_buckets.length <= bucketIndex) {
      _buckets.add(KBucket(k));
    }

    _buckets[bucketIndex].add(peerId);
  }

  List<PeerId> nearestPeers(List<int> targetBytes, {int count = 20}) {
    final sortedPeers = <PeerId>[];
    for (final bucket in _buckets) {
      sortedPeers.addAll(bucket.peers);
    }

    sortedPeers.sort((a, b) {
      final da = xorDistance(a.multihashBytes, targetBytes);
      final db = xorDistance(b.multihashBytes, targetBytes);
      return da.compareTo(db);
    });

    return sortedPeers.take(count).toList(growable: false);
  }

  int _bucketIndex(BigInt distance) {
    if (distance == BigInt.zero) return 0;
    // Simple log2 for bucket index based on XOR distance
    return distance.bitLength - 1;
  }
}

class KBucket {
  KBucket(this.capacity);

  final int capacity;
  final List<PeerId> peers = <PeerId>[];

  void add(PeerId peerId) {
    if (peers.contains(peerId)) {
      // Move to back (most recently seen)
      peers.remove(peerId);
      peers.add(peerId);
      return;
    }

    if (peers.length < capacity) {
      peers.add(peerId);
    } else {
      // Typically we'd ping the least recently seen peer and replace if it doesn't respond
      // For now, just keep the existing peers
    }
  }
}

BigInt xorDistance(List<int> a, List<int> b) {
  final length = a.length > b.length ? a.length : b.length;
  var res = BigInt.zero;
  for (var i = 0; i < length; i++) {
    final byteA = i < a.length ? a[i] : 0;
    final byteB = i < b.length ? b[i] : 0;
    res = (res << 8) | BigInt.from(byteA ^ byteB);
  }
  return res;
}
