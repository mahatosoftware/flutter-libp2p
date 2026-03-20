import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../address/multiaddr.dart';
import '../core/libp2p_stream.dart';
import '../crypto/protobuf.dart';
import '../identity/peer_id.dart';
import '../host/host.dart';
import '../host/peer_store.dart';
import '../host/protocol_registry.dart';
import '../core/retry.dart';
import 'kad_routing.dart';

enum _KadMessageType {
  putValue(0),
  getValue(1),
  addProvider(2),
  getProviders(3),
  findNode(4),
  ping(5);

  const _KadMessageType(this.code);
  final int code;
}

class KadPeer {
  KadPeer({
    required this.peerId,
    required this.addrs,
  });

  final PeerId peerId;
  final List<Multiaddr> addrs;
}

class KadDhtService implements HostService {
  KadDhtService(this.peerStore);

  static const protocolId = '/ipfs/kad/1.0.0';
  static const libp2pProtocolId = '/libp2p/kad/1.0.0';
  final PeerStore peerStore;
  Libp2pHost? _host;
  RoutingTable? _routingTable;
  Timer? _refreshTimer;

  void addPeer(PeerId peerId, {Multiaddr? addr}) {
    _routingTable?.addPeer(peerId, addr: addr);
    if (addr != null && !addr.toString().contains('p2p-circuit')) {
      peerStore.upsertPeer(peerId, addrs: [addr]);
    }
  }

  static const refreshInterval = Duration(minutes: 20);
  static const maxIdleTime = Duration(hours: 1);

  @override
  Iterable<ProtocolRegistration> get protocolRegistrations => <ProtocolRegistration>[
        ProtocolRegistration(protocolId, _handleKadStream),
        ProtocolRegistration(libp2pProtocolId, _handleKadStream),
      ];

  @override
  Future<void> start(Libp2pHost host) async {
    _host = host;
    _routingTable = RoutingTable(host.peerId);
    _refreshTimer = Timer.periodic(refreshInterval, (_) => _maintain());
  }

  @override
  Future<void> stop() async {
    _host = null;
    _routingTable = null;
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  Future<void> bootstrap(Iterable<Multiaddr> peers) async {
    final host = _host;
    if (host == null) {
      throw StateError('KadDhtService has not been started');
    }

    for (final peerAddr in peers) {
      try {
        await host.connect(peerAddr);
      } catch (_) {
        // Skip inaccessible bootstrap nodes
      }
    }

    // After connecting to bootstrap nodes, perform a self-search to fill buckets
    await findPeer(host.peerId);
  }

  Future<PeerRecord?> findPeer(PeerId targetPeerId) async {
    final local = peerStore.getPeer(targetPeerId);
    if (local != null && targetPeerId.toBase58() != _host?.peerId.toBase58()) {
      return local;
    }

    final host = _host;
    final routingTable = _routingTable;
    if (host == null || routingTable == null) {
      throw StateError('KadDhtService has not been started');
    }

    final targetBytes = targetPeerId.multihashBytes;
    final visitedPeers = <String>{host.peerId.toBase58()};
    final peersToQuery = routingTable.nearestPeers(targetBytes);

    while (peersToQuery.isNotEmpty) {
      final queryPeer = peersToQuery.removeAt(0);
      if (visitedPeers.contains(queryPeer.toBase58())) continue;
      visitedPeers.add(queryPeer.toBase58());

      try {
        final record = peerStore.getPeer(queryPeer);
        if (record == null || record.addrs.isEmpty) continue;

        final response = await Retry.withRetry(() async {
          final connection = await host.connect(record.addrs.first);
          final stream = await connection.openStream(protocolId);
          await stream.writeLengthPrefixed(
            _encodeMessage(
              _KadMessage(
                type: _KadMessageType.findNode,
                key: targetBytes,
              ),
            ),
          );
          final res = _decodeMessage(await stream.readLengthPrefixed());
          await stream.close();
          return res;
        }, maxAttempts: 2);

        for (final peer in response.closerPeers) {
          _routingTable?.addPeer(peer.peerId, addr: peer.addrs.isNotEmpty ? peer.addrs.first : null);
          final record = peerStore.upsertPeer(peer.peerId, addrs: peer.addrs);
          if (record.peerId.toBase58() == targetPeerId.toBase58()) {
            return record;
          }
          // Add new peers to the query queue if they are closer
          // (Simplified: just add all for now, as nearestPeers will prioritize)
          peersToQuery.add(peer.peerId);
        }
        peersToQuery.sort((a, b) {
          final da = xorDistance(a.multihashBytes, targetBytes);
          final db = xorDistance(b.multihashBytes, targetBytes);
          return da.compareTo(db);
        });
      } catch (_) {
        // Log and continue
      }
    }
    return null;
  }

  Future<List<PeerRecord>> findProviders(String key) async {
    final localProviders = peerStore
        .getProviders(key)
        .map((provider) => peerStore.upsertPeer(provider.peerId, addrs: provider.addrs))
        .toList(growable: false);

    final results = <String, PeerRecord>{
      for (final provider in localProviders) provider.peerId.toBase58(): provider,
    };

    final host = _host;
    final routingTable = _routingTable;
    if (host == null || routingTable == null) {
      throw StateError('KadDhtService has not been started');
    }

    final targetBytes = Uint8List.fromList(utf8.encode(key));
    final visitedPeers = <String>{host.peerId.toBase58()};
    final peersToQuery = routingTable.nearestPeers(targetBytes);

    while (peersToQuery.isNotEmpty) {
      final queryPeer = peersToQuery.removeAt(0);
      if (visitedPeers.contains(queryPeer.toBase58())) continue;
      visitedPeers.add(queryPeer.toBase58());

      try {
        final record = peerStore.getPeer(queryPeer);
        if (record == null || record.addrs.isEmpty) continue;

        final connection = await host.connect(record.addrs.first);
        final stream = await connection.openStream(protocolId);
        stream.writeLengthPrefixed(
          _encodeMessage(
            _KadMessage(
              type: _KadMessageType.getProviders,
              key: targetBytes,
            ),
          ),
        );
        final response = _decodeMessage(await stream.readLengthPrefixed());
        await stream.close();

        for (final peer in response.providerPeers) {
          _routingTable?.addPeer(peer.peerId, addr: peer.addrs.isNotEmpty ? peer.addrs.first : null);
          results[peer.peerId.toBase58()] = peerStore.upsertPeer(
            peer.peerId,
            addrs: peer.addrs,
          );
        }

        for (final peer in response.closerPeers) {
          _routingTable?.addPeer(peer.peerId, addr: peer.addrs.isNotEmpty ? peer.addrs.first : null);
          peersToQuery.add(peer.peerId);
        }
        peersToQuery.sort((a, b) {
          final da = xorDistance(a.multihashBytes, targetBytes);
          final db = xorDistance(b.multihashBytes, targetBytes);
          return da.compareTo(db);
        });
      } catch (_) {
        // Log and continue
      }
    }

    return results.values.toList(growable: false);
  }

  Future<void> addProvider(String key, PeerId peerId, Iterable<Multiaddr> addrs) async {
    peerStore.addProvider(key, peerId, addrs: addrs);

    final host = _host;
    if (host == null) return;

    // 2. Network announcement: find nearest peers to key and tell them
    final targetBytes = Uint8List.fromList(utf8.encode(key));
    
    // We reuse findPeer logic to find nodes to announce to
    final visitedPeers = <String>{host.peerId.toBase58()};
    final peersToQuery = _routingTable?.nearestPeers(targetBytes) ?? <PeerId>[];

    while (peersToQuery.isNotEmpty) {
      final queryPeer = peersToQuery.removeAt(0);
      if (visitedPeers.contains(queryPeer.toBase58())) continue;
      visitedPeers.add(queryPeer.toBase58());

      try {
        final record = peerStore.getPeer(queryPeer);
        if (record == null || record.addrs.isEmpty) continue;

        final connection = await host.connect(record.addrs.first);
        final stream = await connection.openStream(protocolId);
        
        await stream.writeLengthPrefixed(
          _encodeMessage(
            _KadMessage(
              type: _KadMessageType.addProvider,
              key: targetBytes,
              providerPeers: [
                  KadPeer(peerId: peerId, addrs: addrs.toList()),
              ],
            ),
          ),
        );
        await stream.close();
      } catch (_) {
        // Continue to others
      }
    }
  }

  Future<void> _handleKadStream(
    HostConnection connection,
    Libp2pStream stream,
  ) async {
    final request = _decodeMessage(await stream.readLengthPrefixed());
    switch (request.type) {
      case _KadMessageType.findNode:
        final target = request.key;
        final targetPeer = peerStore.getPeer(PeerId(Uint8List.fromList(target)));
        final peers = targetPeer != null
            ? <KadPeer>[
                KadPeer(peerId: targetPeer.peerId, addrs: targetPeer.addrs),
              ]
            : _nearestPeers(Uint8List.fromList(target));
        stream.writeLengthPrefixed(
          _encodeMessage(
            _KadMessage(
              type: _KadMessageType.findNode,
              closerPeers: peers,
            ),
          ),
        );
      case _KadMessageType.addProvider:
        String key;
        try {
          key = utf8.decode(request.key);
        } catch (_) {
          key = base64.encode(request.key);
        }

        if (request.providerPeers.isNotEmpty) {
          for (final provider in request.providerPeers) {
            peerStore.addProvider(key, provider.peerId, addrs: provider.addrs);
          }
        } else {
          peerStore.addProvider(
            key,
            connection.remotePeerId,
            addrs: <Multiaddr>[connection.remoteAddress],
          );
        }
        await stream.writeLengthPrefixed(
          _encodeMessage(
            _KadMessage(type: _KadMessageType.addProvider),
          ),
        );
      case _KadMessageType.getProviders:
        final keyBytes = request.key;
        String key;
        try {
          key = utf8.decode(keyBytes);
        } catch (_) {
          key = base64.encode(keyBytes);
        }
        final providers = peerStore.getProviders(key);
        stream.writeLengthPrefixed(
          _encodeMessage(
            _KadMessage(
              type: _KadMessageType.getProviders,
              providerPeers: providers
                  .map(
                    (provider) => KadPeer(
                      peerId: provider.peerId,
                      addrs: provider.addrs,
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
        );
      case _KadMessageType.putValue:
      case _KadMessageType.getValue:
      case _KadMessageType.ping:
        break;
    }
    await stream.close();
  }

  Future<void> _maintain() async {
    final routingTable = _routingTable;
    if (routingTable == null) return;

    // 1. Prune stale peers
    final now = DateTime.now();
    for (final bucket in routingTable.buckets) {
      for (final peerId in bucket.peers.toList()) {
        final lastSeen = routingTable.lastSeen(peerId);
        if (lastSeen != null && now.difference(lastSeen) > maxIdleTime) {
          routingTable.removePeer(peerId);
          peerStore.markDisconnected(peerId);
        }
      }
    }

    // 2. Refresh buckets
    // For each bucket that needs refresh, generate a random ID in that range and find it
    for (var i = 0; i < routingTable.buckets.length; i++) {
      if (routingTable.buckets.elementAt(i).peers.isEmpty) continue;
      
      final randomTarget = _generateRandomTargetInBucketRange(i);
      await findPeer(PeerId(randomTarget));
    }
  }

  Uint8List _generateRandomTargetInBucketRange(int bucketIndex) {
    // Generate an ID whose XOR distance's bitLength is related to bucketIndex
    final target = Uint8List(32);
    final local = _host!.peerId.multihashBytes;
    
    // Copy local prefix and modify bits at bucketIndex
    for (var i = 0; i < 32; i++) {
        target[i] = local[i];
    }
    
    final byteIdx = bucketIndex ~/ 8;
    final bitIdx = bucketIndex % 8;
    if (byteIdx < 32) {
      target[byteIdx] ^= (1 << bitIdx); // Flip bit to change distance
      // Randomize remaining low bits?
    }
    return target;
  }

  List<KadPeer> _nearestPeers(Uint8List target) {
    var peers = _routingTable?.nearestPeers(target, count: 8) ?? <PeerId>[];

    return peers
        .map((peerId) {
          final record = peerStore.getPeer(peerId);
          if (record == null) return null;
          return KadPeer(peerId: record.peerId, addrs: record.addrs);
        })
        .whereType<KadPeer>()
        .toList(growable: false);
  }
}

class _KadMessage {
  const _KadMessage({
    required this.type,
    this.key = const <int>[],
    this.closerPeers = const <KadPeer>[],
    this.providerPeers = const <KadPeer>[],
  });

  final _KadMessageType type;
  final List<int> key;
  final List<KadPeer> closerPeers;
  final List<KadPeer> providerPeers;
}

Uint8List _encodeMessage(_KadMessage message) {
  return Uint8List.fromList([
    ...protoEnum(1, message.type.code),
    if (message.key.isNotEmpty) ...protoBytes(3, message.key),
    for (final peer in message.closerPeers) ...protoBytes(8, _encodePeer(peer)),
    for (final peer in message.providerPeers) ...protoBytes(9, _encodePeer(peer)),
  ]);
}

Uint8List _encodePeer(KadPeer peer) {
  return Uint8List.fromList([
    ...protoBytes(1, peer.peerId.multihashBytes),
    for (final addr in peer.addrs) ...protoBytes(2, addr.toBytes()),
  ]);
}

_KadMessage _decodeMessage(Uint8List bytes) {
  _KadMessageType type = _KadMessageType.findNode;
  List<int> key = const <int>[];
  final closerPeers = <KadPeer>[];
  final providerPeers = <KadPeer>[];

  var offset = 0;
  while (offset < bytes.length) {
    final field = _readVarint(bytes, offset);
    offset += field.length;
    final fieldNumber = field.value >> 3;
    final wireType = field.value & 0x07;
    if (wireType == 0) {
      final value = _readVarint(bytes, offset);
      offset += value.length;
      if (fieldNumber == 1) {
        type = _KadMessageType.values.firstWhere(
          (candidate) => candidate.code == value.value,
          orElse: () => _KadMessageType.findNode,
        );
      }
      continue;
    }
    if (wireType != 2) {
      throw FormatException('unsupported kad wire type: $wireType');
    }
    final length = _readVarint(bytes, offset);
    offset += length.length;
    final value = Uint8List.fromList(bytes.sublist(offset, offset + length.value));
    offset += length.value;
    if (fieldNumber == 3) {
      key = value;
    } else if (fieldNumber == 8) {
      closerPeers.add(_decodePeer(value));
    } else if (fieldNumber == 9) {
      providerPeers.add(_decodePeer(value));
    }
  }

  return _KadMessage(
    type: type,
    key: key,
    closerPeers: closerPeers,
    providerPeers: providerPeers,
  );
}

KadPeer _decodePeer(Uint8List bytes) {
  PeerId? peerId;
  final addrs = <Multiaddr>[];

  var offset = 0;
  while (offset < bytes.length) {
    final field = _readVarint(bytes, offset);
    offset += field.length;
    final fieldNumber = field.value >> 3;
    final wireType = field.value & 0x07;
    if (wireType != 2) {
      throw FormatException('unsupported kad peer wire type: $wireType');
    }
    final length = _readVarint(bytes, offset);
    offset += length.length;
    final value = Uint8List.fromList(bytes.sublist(offset, offset + length.value));
    offset += length.value;
    if (fieldNumber == 1) {
      peerId = PeerId(value);
    } else if (fieldNumber == 2) {
      addrs.add(Multiaddr.fromBytes(value));
    }
  }

  if (peerId == null) {
    throw const FormatException('kad peer message missing peer id');
  }
  return KadPeer(peerId: peerId, addrs: addrs);
}


class _VarintResult {
  _VarintResult(this.value, this.length);

  final int value;
  final int length;
}

_VarintResult _readVarint(List<int> bytes, int offset) {
  var shift = 0;
  var value = 0;
  var index = offset;
  while (index < bytes.length) {
    final byte = bytes[index];
    value |= (byte & 0x7f) << shift;
    index++;
    if ((byte & 0x80) == 0) {
      return _VarintResult(value, index - offset);
    }
    shift += 7;
  }
  throw const FormatException('incomplete varint');
}
