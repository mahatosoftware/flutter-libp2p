import '../address/multiaddr.dart';
import '../identity/peer_id.dart';

class RoutingTable {
  RoutingTable(this.localPeerId, {this.k = 20, this.maxPeersPerIpRange = 2});

  final PeerId localPeerId;
  final int k;
  final int maxPeersPerIpRange;
  final List<KBucket> _buckets = <KBucket>[];
  final Map<String, DateTime> _lastSeen = <String, DateTime>{};
  final Map<String, int> _ipRangeCount = <String, int>{};


  Iterable<KBucket> get buckets => _buckets;

  void addPeer(PeerId peerId, {Multiaddr? addr}) {
    if (peerId == localPeerId) return;

    final range = addr != null ? _getIpRange(addr) : null;
    if (range != null) {
      final count = _ipRangeCount[range] ?? 0;
      if (count >= maxPeersPerIpRange && !_isPeerInRange(peerId, range)) {
        return; // Too many peers from this range
      }
    }

    _lastSeen[peerId.toBase58()] = DateTime.now();

    final distance = xorDistance(localPeerId.multihashBytes, peerId.multihashBytes);
    final bucketIndex = _bucketIndex(distance);

    while (_buckets.length <= bucketIndex) {
      _buckets.add(KBucket(k));
    }

    if (!_buckets[bucketIndex].peers.contains(peerId)) {
        if (range != null) {
            _ipRangeCount[range] = (_ipRangeCount[range] ?? 0) + 1;
        }
    }
    _buckets[bucketIndex].add(peerId);
  }

  void removePeer(PeerId peerId, {Multiaddr? addr}) {
    _lastSeen.remove(peerId.toBase58());
    final range = addr != null ? _getIpRange(addr) : null;
    if (range != null) {
        _ipRangeCount[range] = (_ipRangeCount[range] ?? 1) - 1;
    }
    for (final bucket in _buckets) {
      bucket.peers.remove(peerId);
    }
  }

  DateTime? lastSeen(PeerId peerId) => _lastSeen[peerId.toBase58()];

  String? _getIpRange(Multiaddr addr) {
    final ip4 = addr.valueForProtocol('ip4');
    if (ip4 != null) {
      final parts = ip4.split('.');
      if (parts.length == 4) {
        return 'ip4:${parts[0]}.${parts[1]}.${parts[2]}'; // /24
      }
    }
    final ip6 = addr.valueForProtocol('ip6');
    if (ip6 != null) {
        final parts = ip6.split(':');
        if (parts.length >= 3) {
            return 'ip6:${parts[0]}:${parts[1]}:${parts[2]}'; // /48
        }
    }
    return null;
  }

  bool _isPeerInRange(PeerId peerId, String range) {
      for(final bucket in _buckets) {
          if (bucket.peers.contains(peerId)) return true;
      }
      return false;
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

    return sortedPeers.take(count).toList(growable: true);
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
