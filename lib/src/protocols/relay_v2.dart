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

class RelayService implements HostService {
  RelayService(this.peerStore);

  static const hopProtocolId = '/libp2p/circuit/relay/0.2.0/hop';
  static const stopProtocolId = '/libp2p/circuit/relay/0.2.0/stop';
  final PeerStore peerStore;
  final Map<String, RelayReservation> _reservations = <String, RelayReservation>{};
  Libp2pHost? _host;

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
    stream.writeLengthPrefixed(_encodeRelayMessage(_RelayMessage(type: _RelayMessageType.reserve)));
    final response = _decodeRelayMessage(await stream.readLengthPrefixed());
    await stream.close();
    final reservation = RelayReservation(
      relayPeerId: relayConnection.remotePeerId,
      relayAddrs: response.addrs,
      expiresAt: response.expiry ?? DateTime.now().add(const Duration(hours: 1)),
    );
    _reservations[relayConnection.remotePeerId.toBase58()] = reservation;
    return reservation;
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
        stream.writeLengthPrefixed(
          _encodeRelayMessage(
            _RelayMessage(
              type: _RelayMessageType.status,
              expiry: expiry,
              addrs: host.listenAddrs,
            ),
          ),
        );
      case _RelayMessageType.status:
        break;
    }
    await stream.close();
  }
}

enum _RelayMessageType {
  reserve(0),
  status(1),
  stop(2);

  const _RelayMessageType(this.code);
  final int code;
}

class _RelayMessage {
  const _RelayMessage({
    required this.type,
    this.expiry,
    this.addrs = const <Multiaddr>[],
    this.payload = const <int>[],
  });

  final _RelayMessageType type;
  final DateTime? expiry;
  final List<Multiaddr> addrs;
  final List<int> payload;
}

Uint8List _encodeRelayMessage(_RelayMessage message) {
  return Uint8List.fromList([
    ...protoEnum(1, message.type.code),
    if (message.expiry != null) ...protoBytes(2, Uint8List(8)..buffer.asByteData().setInt64(0, message.expiry!.millisecondsSinceEpoch)),
    for (final addr in message.addrs) ...protoBytes(3, addr.toBytes()),
    if (message.payload.isNotEmpty) ...protoBytes(4, message.payload),
  ]);
}

_RelayMessage _decodeRelayMessage(Uint8List bytes) {
  var type = _RelayMessageType.reserve;
  DateTime? expiry;
  final addrs = <Multiaddr>[];

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
          orElse: () => _RelayMessageType.reserve,
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
      expiry = DateTime.fromMillisecondsSinceEpoch(
        ByteData.sublistView(value).getInt64(0),
      );
    } else if (fieldNumber == 3) {
      addrs.add(Multiaddr.fromBytes(value));
    }
  }

  return _RelayMessage(type: type, expiry: expiry, addrs: addrs);
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
