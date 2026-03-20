import 'dart:convert';
import 'dart:typed_data';

import '../address/multiaddr.dart';
import '../core/libp2p_stream.dart';
import '../crypto/protobuf.dart';
import '../identity/peer_id.dart';
import '../host/host.dart';
import '../host/peer_store.dart';
import '../host/protocol_registry.dart';

enum _KadMessageType {
  findNode(0),
  findNodeResponse(1),
  addProvider(2),
  getProviders(3),
  getProvidersResponse(4);

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
  final PeerStore peerStore;
  Libp2pHost? _host;

  @override
  Iterable<ProtocolRegistration> get protocolRegistrations => <ProtocolRegistration>[
        ProtocolRegistration(protocolId, _handleKadStream),
      ];

  @override
  Future<void> start(Libp2pHost host) async {
    _host = host;
  }

  @override
  Future<void> stop() async {
    _host = null;
  }

  Future<void> bootstrap(Iterable<Multiaddr> peers) async {
    final host = _host;
    if (host == null) {
      throw StateError('KadDhtService has not been started');
    }
    for (final peerAddr in peers) {
      final peerId = peerAddr.valueForProtocol('p2p');
      if (peerId == null) {
        continue;
      }
      peerStore.upsertPeer(
        PeerId.fromBase58(peerId),
        addrs: <Multiaddr>[peerAddr],
      );
    }
  }

  Future<PeerRecord?> findPeer(PeerId targetPeerId) async {
    final local = peerStore.getPeer(targetPeerId);
    if (local != null) {
      return local;
    }

    final host = _host;
    if (host == null) {
      throw StateError('KadDhtService has not been started');
    }

    for (final connection in host.connectionManager.connections) {
      final stream = await connection.openStream(protocolId);
      stream.writeLengthPrefixed(
        _encodeMessage(
          _KadMessage(
            type: _KadMessageType.findNode,
            key: utf8.encode(targetPeerId.toBase58()),
          ),
        ),
      );
      final response = _decodeMessage(await stream.readLengthPrefixed());
      await stream.close();
      for (final peer in response.peers) {
        final record = peerStore.upsertPeer(peer.peerId, addrs: peer.addrs);
        if (record.peerId.toBase58() == targetPeerId.toBase58()) {
          return record;
        }
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
    if (host == null) {
      throw StateError('KadDhtService has not been started');
    }

    for (final connection in host.connectionManager.connections) {
      final stream = await connection.openStream(protocolId);
      stream.writeLengthPrefixed(
        _encodeMessage(
          _KadMessage(
            type: _KadMessageType.getProviders,
            key: utf8.encode(key),
          ),
        ),
      );
      final response = _decodeMessage(await stream.readLengthPrefixed());
      await stream.close();
      for (final peer in response.peers) {
        results[peer.peerId.toBase58()] = peerStore.upsertPeer(
          peer.peerId,
          addrs: peer.addrs,
        );
      }
    }

    return results.values.toList(growable: false);
  }

  void addProvider(String key, PeerId peerId, Iterable<Multiaddr> addrs) {
    peerStore.addProvider(key, peerId, addrs: addrs);
  }

  Future<void> _handleKadStream(
    HostConnection connection,
    Libp2pStream stream,
  ) async {
    final request = _decodeMessage(await stream.readLengthPrefixed());
    switch (request.type) {
      case _KadMessageType.findNode:
        final target = utf8.decode(request.key);
        final targetPeer = peerStore.getPeerByBase58(target);
        final peers = targetPeer != null
            ? <KadPeer>[
                KadPeer(peerId: targetPeer.peerId, addrs: targetPeer.addrs),
              ]
            : _nearestPeers(target);
        stream.writeLengthPrefixed(
          _encodeMessage(
            _KadMessage(
              type: _KadMessageType.findNodeResponse,
              peers: peers,
            ),
          ),
        );
      case _KadMessageType.addProvider:
        final key = utf8.decode(request.key);
        peerStore.addProvider(
          key,
          connection.remotePeerId,
          addrs: <Multiaddr>[connection.remoteAddress],
        );
        stream.writeLengthPrefixed(
          _encodeMessage(
            _KadMessage(type: _KadMessageType.getProvidersResponse),
          ),
        );
      case _KadMessageType.getProviders:
        final key = utf8.decode(request.key);
        final providers = peerStore.getProviders(key);
        stream.writeLengthPrefixed(
          _encodeMessage(
            _KadMessage(
              type: _KadMessageType.getProvidersResponse,
              peers: providers
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
      case _KadMessageType.findNodeResponse:
      case _KadMessageType.getProvidersResponse:
        break;
    }
    await stream.close();
  }

  List<KadPeer> _nearestPeers(String targetPeerId) {
    final targetBytes = utf8.encode(targetPeerId);
    final peers = peerStore.peers.toList(growable: false)
      ..sort(
        (left, right) => _xorDistance(left.peerId.multihashBytes, targetBytes)
            .compareTo(_xorDistance(right.peerId.multihashBytes, targetBytes)),
      );
    return peers
        .take(8)
        .map((record) => KadPeer(peerId: record.peerId, addrs: record.addrs))
        .toList(growable: false);
  }
}

class _KadMessage {
  const _KadMessage({
    required this.type,
    this.key = const <int>[],
    this.peers = const <KadPeer>[],
  });

  final _KadMessageType type;
  final List<int> key;
  final List<KadPeer> peers;
}

Uint8List _encodeMessage(_KadMessage message) {
  return Uint8List.fromList([
    ...protoEnum(1, message.type.code),
    if (message.key.isNotEmpty) ...protoBytes(2, message.key),
    for (final peer in message.peers) ...protoBytes(3, _encodePeer(peer)),
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
  final peers = <KadPeer>[];

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
    if (fieldNumber == 2) {
      key = value;
    } else if (fieldNumber == 3) {
      peers.add(_decodePeer(value));
    }
  }

  return _KadMessage(type: type, key: key, peers: peers);
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

int _xorDistance(List<int> left, List<int> right) {
  final maxLength = left.length > right.length ? left.length : right.length;
  var distance = 0;
  for (var i = 0; i < maxLength; i++) {
    final leftByte = i < left.length ? left[i] : 0;
    final rightByte = i < right.length ? right[i] : 0;
    distance = (distance << 1) ^ (leftByte ^ rightByte);
  }
  return distance;
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
