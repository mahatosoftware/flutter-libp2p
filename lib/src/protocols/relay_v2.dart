import 'dart:async';
import 'dart:typed_data';

import '../address/multiaddr.dart';
import '../core/libp2p_stream.dart';
import '../crypto/protobuf.dart';
import '../identity/peer_id.dart';
import '../host/host.dart';
import '../host/peer_store.dart';
import '../host/protocol_registry.dart';

class RelayReservation {
  RelayReservation({
    required this.relayPeerId,
    required this.relayAddrs,
    required this.expiresAt,
  });

  final PeerId relayPeerId;
  final List<Multiaddr> relayAddrs;
  final DateTime expiresAt;
}

class _RelayLimit {
  const _RelayLimit({this.durationSeconds, this.dataBytes});
  final int? durationSeconds;
  final int? dataBytes;
}

class RelayService implements HostService {
  RelayService(this.peerStore);

  static const hopProtocolId = '/libp2p/circuit/relay/0.2.0/hop';
  static const stopProtocolId = '/libp2p/circuit/relay/0.2.0/stop';
  final PeerStore peerStore;
  final Map<String, RelayReservation> _reservations = <String, RelayReservation>{};
  final Map<String, Libp2pStream> _activeHops = <String, Libp2pStream>{};
  Libp2pHost? _host;
  
  static const defaultLimitSeconds = 3600; // 1 hour
  static const defaultLimitData = 1 << 20; // 1 MB

  @override
  Iterable<ProtocolRegistration> get protocolRegistrations => <ProtocolRegistration>[
        ProtocolRegistration(hopProtocolId, _handleHopStream),
        ProtocolRegistration(stopProtocolId, _handleStopStream),
      ];

  @override
  Future<void> start(Libp2pHost host) async {
    _host = host;
  }

  @override
  Future<void> stop() async {
    _host = null;
    _reservations.clear();
  }

  RelayReservation? reservationFor(PeerId peerId) => _reservations[peerId.toBase58()];

  Future<RelayReservation> reserve(HostConnection relayConnection) async {
    final stream = await relayConnection.openStream(hopProtocolId);
    await stream.writeLengthPrefixed(_encodeRelayMessage(_RelayMessage(type: _RelayMessageType.reserve)));
    final response = _decodeRelayMessage(await stream.readLengthPrefixed());
    await stream.close();

    if (response.type != _RelayMessageType.status || response.status != _RelayStatus.ok) {
      throw StateError('relay reservation failed: ${response.status}');
    }

    final reservation = RelayReservation(
      relayPeerId: relayConnection.remotePeerId,
      relayAddrs: response.addrs,
      expiresAt: response.expiry ?? DateTime.now().add(const Duration(hours: 1)),
    );
    _reservations[relayConnection.remotePeerId.toBase58()] = reservation;
    return reservation;
  }

  Future<Libp2pStream> connect(HostConnection relayConnection, PeerId destinationPeerId) async {
    final stream = await relayConnection.openStream(hopProtocolId);
    await stream.writeLengthPrefixed(
      _encodeRelayMessage(
        _RelayMessage(
          type: _RelayMessageType.connect,
          peerId: destinationPeerId,
        ),
      ),
    );
    final response = _decodeRelayMessage(await stream.readLengthPrefixed());
    if (response.type != _RelayMessageType.status) {
      await stream.close();
      throw StateError('relay connection failed: ${response.type}');
    }
    return stream;
  }

  Future<void> _handleHopStream(
    HostConnection connection,
    Libp2pStream stream,
  ) async {
    final request = _decodeRelayMessage(await stream.readLengthPrefixed());
    switch (request.type) {
      case _RelayMessageType.reserve:
        final host = _host;
        if (host == null) {
          throw StateError('RelayService has not been started');
        }
        final expiry = DateTime.now().add(const Duration(hours: 1));
        _reservations[connection.remotePeerId.toBase58()] = RelayReservation(
          relayPeerId: host.peerId,
          relayAddrs: host.listenAddrs,
          expiresAt: expiry,
        );
        peerStore.upsertPeer(connection.remotePeerId, addrs: <Multiaddr>[connection.remoteAddress]);
        await stream.writeLengthPrefixed(
          _encodeRelayMessage(
            _RelayMessage(
              type: _RelayMessageType.status,
              status: _RelayStatus.ok,
              expiry: expiry,
              addrs: host.listenAddrs,
            ),
          ),
        );
        await stream.close();
      case _RelayMessageType.connect:
        final destinationPeerId = request.peerId;
        if (destinationPeerId == null) {
          await stream.writeLengthPrefixed(_encodeRelayMessage(_RelayMessage(type: _RelayMessageType.status))); // Should be error
          await stream.close();
          return;
        }

        final destRecord = peerStore.getPeer(destinationPeerId);
        if (destRecord == null || destRecord.addrs.isEmpty) {
          await stream.writeLengthPrefixed(_encodeRelayMessage(_RelayMessage(type: _RelayMessageType.status))); // Should be error
          await stream.close();
          return;
        }

        try {
          final host = _host!;
          final destConnection = await host.connect(destRecord.addrs.first);
          final destStream = await destConnection.openStream(stopProtocolId);

          await destStream.writeLengthPrefixed(
            _encodeRelayMessage(
              _RelayMessage(
                type: _RelayMessageType.connect,
                peerId: connection.remotePeerId,
              ),
            ),
          );

          final stopResponse = _decodeRelayMessage(await destStream.readLengthPrefixed());
          if (stopResponse.type != _RelayMessageType.status || stopResponse.status != _RelayStatus.ok) {
            await destStream.close();
            await stream.writeLengthPrefixed(_encodeRelayMessage(_RelayMessage(type: _RelayMessageType.status, status: _RelayStatus.connectionFailed)));
            await stream.close();
            return;
          }

          await stream.writeLengthPrefixed(_encodeRelayMessage(_RelayMessage(type: _RelayMessageType.status, status: _RelayStatus.ok)));

          // Pipe data and enforce duration & data limits
          _pipe(
            stream,
            destStream,
            duration: const Duration(seconds: defaultLimitSeconds),
            maxBytes: defaultLimitData,
          );
        } catch (_) {
          await stream.close();
        }
      case _RelayMessageType.status:
        await stream.close();
      case _RelayMessageType.stop:
        await stream.close();
    }
  }

  Future<void> _handleStopStream(
    HostConnection connection,
    Libp2pStream stream,
  ) async {
    final request = _decodeRelayMessage(await stream.readLengthPrefixed());
    if (request.type != _RelayMessageType.connect) {
      await stream.close();
      return;
    }

    // Notify host of incoming relayed connection?
    // For now just accept and return status
    await stream.writeLengthPrefixed(
      _encodeRelayMessage(
        _RelayMessage(
          type: _RelayMessageType.status,
          status: _RelayStatus.ok,
        ),
      ),
    );

    // This stream is now a relayed connection to request.peerId
    // We should probably hand it off to the Host to handle as a new connection
    final host = _host;
    if (host != null && request.peerId != null) {
      host.handleRelayedStream(request.peerId!, stream);
    }
  }

  void _pipe(
    Libp2pStream s1,
    Libp2pStream s2, {
    Duration? duration,
    int? maxBytes,
  }) {
    int bytes = 0;
    
    final s1Sub = s1.inputStream.listen((data) {
      if (maxBytes != null && (bytes + data.length) > maxBytes) {
        s1.close();
        s2.close();
        return;
      }
      bytes += data.length;
      s2.write(data);
    }, onDone: s2.close);
    
    final s2Sub = s2.inputStream.listen((data) {
      if (maxBytes != null && (bytes + data.length) > maxBytes) {
        s1.close();
        s2.close();
        return;
      }
      bytes += data.length;
      s1.write(data);
    }, onDone: s1.close);

    if (duration != null) {
      Timer(duration, () {
        s1Sub.cancel();
        s2Sub.cancel();
        s1.close();
        s2.close();
      });
    }
  }
}

enum _RelayMessageType {
  reserve(0),
  connect(1),
  status(2),
  stop(3);

  const _RelayMessageType(this.code);
  final int code;
}

class _RelayMessage {
  const _RelayMessage({
    required this.type,
    this.peerId,
    this.expiry,
    this.addrs = const <Multiaddr>[],
    this.payload = const <int>[],
    this.status,
    this.limit,
  });

  final _RelayMessageType type;
  final PeerId? peerId;
  final DateTime? expiry;
  final List<Multiaddr> addrs;
  final List<int> payload;
  final _RelayStatus? status;
  final _RelayLimit? limit;
}

enum _RelayStatus {
  ok(100),
  reservationRefused(200),
  resourceLimitExceeded(201),
  permissionDenied(202),
  connectionFailed(300),
  noReservation(400),
  malformedMessage(401),
  unexpectedMessage(402);

  const _RelayStatus(this.code);
  final int code;
}

Uint8List _encodeRelayMessage(_RelayMessage message) {
  return Uint8List.fromList([
    ...protoEnum(1, message.type.code),
    if (message.peerId != null) ...protoBytes(2, _encodePeer(message.peerId!, message.addrs)),
    if (message.expiry != null) ...protoBytes(3, _encodeReservation(message.expiry!, message.addrs)),
    if (message.limit != null) ...protoBytes(4, _encodeLimit(message.limit!)),
    if (message.status != null) ...protoEnum(5, message.status!.code),
  ]);
}

Uint8List _encodeLimit(_RelayLimit limit) {
  return Uint8List.fromList([
    if (limit.durationSeconds != null) ...protoVarint(1, limit.durationSeconds!),
    if (limit.dataBytes != null) ...protoVarint(2, limit.dataBytes!),
  ]);
}

Uint8List _encodePeer(PeerId peerId, List<Multiaddr> addrs) {
  return Uint8List.fromList([
    ...protoBytes(1, peerId.multihashBytes),
    for (final addr in addrs) ...protoBytes(2, addr.toBytes()),
  ]);
}

Uint8List _encodeReservation(DateTime expiry, List<Multiaddr> addrs) {
  return Uint8List.fromList([
    ...protoBytes(1, Uint8List(8)..buffer.asByteData().setInt64(0, (expiry.millisecondsSinceEpoch / 1000).floor())),
    for (final addr in addrs) ...protoBytes(2, addr.toBytes()),
  ]);
}

_RelayMessage _decodeRelayMessage(Uint8List bytes) {
  var type = _RelayMessageType.reserve;
  PeerId? peerId;
  DateTime? expiry;
  final addrs = <Multiaddr>[];
  _RelayStatus? status;
  _RelayLimit? limit;

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
        type = _RelayMessageType.values.firstWhere(
          (candidate) => candidate.code == value.value,
          orElse: () => _RelayMessageType.status,
        );
      } else if (fieldNumber == 5) {
        status = _RelayStatus.values.firstWhere(
          (candidate) => candidate.code == value.value,
          orElse: () => _RelayStatus.ok,
        );
      }
      continue;
    }
    if (wireType != 2) {
      throw FormatException('unsupported relay wire type: $wireType');
    }
    final length = _readVarint(bytes, offset);
    offset += length.length;
    final value = Uint8List.fromList(bytes.sublist(offset, offset + length.value));
    offset += length.value;

    if (fieldNumber == 2) {
      // Decode Peer
      final peer = _decodePeer(value);
      peerId = peer.peerId;
      addrs.addAll(peer.addrs);
    } else if (fieldNumber == 3) {
      // Decode Reservation
      final res = _decodeReservation(value);
      expiry = res.expiry;
      addrs.addAll(res.addrs);
    } else if (fieldNumber == 4) {
      // Decode Limit
      limit = _decodeLimit(value);
    }
  }

  return _RelayMessage(
    type: type,
    peerId: peerId,
    expiry: expiry,
    addrs: addrs,
    status: status,
    limit: limit,
  );
}

_RelayLimit _decodeLimit(Uint8List bytes) {
  int? duration;
  int? data;
  var offset = 0;
  while (offset < bytes.length) {
    final field = _readVarint(bytes, offset);
    offset += field.length;
    final fieldNumber = field.value >> 3;
    final val = _readVarint(bytes, offset);
    offset += val.length;
    if (fieldNumber == 1) duration = val.value;
    if (fieldNumber == 2) data = val.value;
  }
  return _RelayLimit(durationSeconds: duration, dataBytes: data);
}

class _KadPeerInfo {
  _KadPeerInfo(this.peerId, this.addrs);
  final PeerId peerId;
  final List<Multiaddr> addrs;
}

_KadPeerInfo _decodePeer(Uint8List bytes) {
  PeerId? peerId;
  final addrs = <Multiaddr>[];
  var offset = 0;
  while (offset < bytes.length) {
    final field = _readVarint(bytes, offset);
    offset += field.length;
    final fieldNumber = field.value >> 3;
    final value = _readBytes(bytes, offset);
    offset += value.totalLength;
    if (fieldNumber == 1) peerId = PeerId(value.content);
    if (fieldNumber == 2) addrs.add(Multiaddr.fromBytes(value.content));
  }
  return _KadPeerInfo(peerId!, addrs);
}

class _ReservationInfo {
  _ReservationInfo(this.expiry, this.addrs);
  final DateTime expiry;
  final List<Multiaddr> addrs;
}

_ReservationInfo _decodeReservation(Uint8List bytes) {
  DateTime? expiry;
  final addrs = <Multiaddr>[];
  var offset = 0;
  while (offset < bytes.length) {
    final field = _readVarint(bytes, offset);
    offset += field.length;
    final fieldNumber = field.value >> 3;
    final value = _readBytes(bytes, offset);
    offset += value.totalLength;
    if (fieldNumber == 1) {
      expiry = DateTime.fromMillisecondsSinceEpoch(
        ByteData.sublistView(value.content).getInt64(0) * 1000,
      );
    }
    if (fieldNumber == 2) addrs.add(Multiaddr.fromBytes(value.content));
  }
  return _ReservationInfo(expiry ?? DateTime.now(), addrs);
}

class _BytesResult {
  _BytesResult(this.content, this.totalLength);
  final Uint8List content;
  final int totalLength;
}

_BytesResult _readBytes(Uint8List bytes, int offset) {
  final length = _readVarint(bytes, offset);
  final content = bytes.sublist(offset + length.length, offset + length.length + length.value);
  return _BytesResult(content, length.length + length.value);
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
