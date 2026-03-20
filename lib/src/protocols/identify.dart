import 'dart:convert';
import 'dart:typed_data';

import '../address/multiaddr.dart';
import '../core/libp2p_stream.dart';
import '../crypto/protobuf.dart';
import '../identity/peer_id.dart';

class IdentifySnapshot {
  IdentifySnapshot({
    required this.protocolVersion,
    required this.agentVersion,
    required this.publicKey,
    required this.listenAddrs,
    required this.observedAddr,
    required this.protocols,
  });

  final String protocolVersion;
  final String agentVersion;
  final Uint8List publicKey;
  final List<Multiaddr> listenAddrs;
  final Multiaddr observedAddr;
  final List<String> protocols;
}

class IdentifyProtocol {
  static const protocolId = '/ipfs/id/1.0.0';

  static Future<void> writeMessage(
    Libp2pStream stream,
    IdentifySnapshot snapshot,
  ) async {
    final bytes = <int>[
      ...protoString(5, snapshot.protocolVersion),
      ...protoString(6, snapshot.agentVersion),
      ...protoBytes(1, snapshot.publicKey),
      for (final address in snapshot.listenAddrs)
        ...protoBytes(2, address.toBytes()),
      ...protoBytes(4, snapshot.observedAddr.toBytes()),
      for (final protocol in snapshot.protocols) ...protoString(3, protocol),
    ];
    stream.writeLengthPrefixed(bytes);
    await stream.close();
  }

  static Future<IdentifySnapshot> readMessage(Libp2pStream stream) async {
    final bytes = await stream.readLengthPrefixed();
    String protocolVersion = '';
    String agentVersion = '';
    Uint8List publicKey = Uint8List(0);
    final listenAddrs = <Multiaddr>[];
    Multiaddr? observedAddr;
    final protocols = <String>[];

    var offset = 0;
    while (offset < bytes.length) {
      final key = _readVarint(bytes, offset);
      offset += key.length;
      final fieldNumber = key.value >> 3;
      final wireType = key.value & 0x07;
      if (wireType != 2) {
        throw FormatException('unsupported identify wire type: $wireType');
      }
      final length = _readVarint(bytes, offset);
      offset += length.length;
      final value = Uint8List.fromList(
        bytes.sublist(offset, offset + length.value),
      );
      offset += length.value;

      switch (fieldNumber) {
        case 1:
          publicKey = value;
          break;
        case 2:
          listenAddrs.add(Multiaddr.fromBytes(value));
          break;
        case 3:
          protocols.add(utf8.decode(value));
          break;
        case 4:
          observedAddr = Multiaddr.fromBytes(value);
          break;
        case 5:
          protocolVersion = utf8.decode(value);
          break;
        case 6:
          agentVersion = utf8.decode(value);
          break;
      }
    }

    await stream.close();
    if (observedAddr == null) {
      throw const FormatException(
        'identify message is missing observed address',
      );
    }
    return IdentifySnapshot(
      protocolVersion: protocolVersion,
      agentVersion: agentVersion,
      publicKey: publicKey,
      listenAddrs: listenAddrs,
      observedAddr: observedAddr,
      protocols: protocols,
    );
  }

  static Uint8List marshalPublicKey(Uint8List rawPublicKey) {
    return PeerId.marshalPublicKey(KeyType.ed25519, rawPublicKey);
  }
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
