import 'dart:async';
import 'dart:typed_data';

import '../address/multiaddr.dart';
import '../core/libp2p_stream.dart';
import '../crypto/protobuf.dart';
import '../identity/peer_id.dart';
import '../host/host.dart';
import '../host/protocol_registry.dart';

enum _DcutrMessageType {
  connect(0),
  sync(1);

  const _DcutrMessageType(this.code);
  final int code;
}

class _DcutrMessage {
  const _DcutrMessage({required this.type, this.addrs = const <Multiaddr>[]});
  final _DcutrMessageType type;
  final List<Multiaddr> addrs;
}

class DcutrProtocol implements HostService {
  DcutrProtocol();

  static const protocolId = '/libp2p/dcutr';
  Libp2pHost? _host;

  @override
  Iterable<ProtocolRegistration> get protocolRegistrations => [
        ProtocolRegistration(protocolId, _handleDcutrStream),
      ];

  @override
  Future<void> start(Libp2pHost host) async {
    _host = host;
  }

  @override
  Future<void> stop() async {
    _host = null;
  }

  Future<void> attemptHolePunch(HostConnection relayedConnection) async {
    final host = _host;
    if (host == null) return;

    // 1. Open DCUtR stream over the relayed connection
    final stream = await relayedConnection.openStream(protocolId);
    
    // 2. Send our listen addresses
    await stream.writeLengthPrefixed(
      _encodeMessage(
        _DcutrMessage(
          type: _DcutrMessageType.connect,
          addrs: host.listenAddrs,
        ),
      ),
    );

    // 3. Receive target's addresses
    final response = _decodeMessage(await stream.readLengthPrefixed());
    if (response.type != _DcutrMessageType.connect) {
      await stream.close();
      return;
    }

    // 4. Synchronize timing (optional but recommended)
    await stream.writeLengthPrefixed(_encodeMessage(_DcutrMessage(type: _DcutrMessageType.sync)));
    await stream.readLengthPrefixed(); // Wait for their SYNC
    await stream.close();

    // 5. Hole punch: Simultaneously dial target's direct addresses
    // We do this in a separate future so we don't block the stream handling
    unawaited(_doHolePunch(relayedConnection.remotePeerId, response.addrs));
  }

  Future<void> _handleDcutrStream(HostConnection connection, Libp2pStream stream) async {
    final host = _host;
    if (host == null) {
      await stream.close();
      return;
    }

    // 1. Receive initiator's addresses
    final request = _decodeMessage(await stream.readLengthPrefixed());
    if (request.type != _DcutrMessageType.connect) {
      await stream.close();
      return;
    }

    // 2. Send our own addresses back
    await stream.writeLengthPrefixed(
      _encodeMessage(
        _DcutrMessage(
          type: _DcutrMessageType.connect,
          addrs: host.listenAddrs,
        ),
      ),
    );

    // 3. Synchronize
    await stream.readLengthPrefixed(); // Wait for initiator SYNC
    await stream.writeLengthPrefixed(_encodeMessage(_DcutrMessage(type: _DcutrMessageType.sync)));
    await stream.close();

    // 4. Hole punch: Dial initiator's direct addresses
    unawaited(_doHolePunch(connection.remotePeerId, request.addrs));
  }

  Future<void> _doHolePunch(PeerId peerId, List<Multiaddr> addrs) async {
    final host = _host;
    if (host == null) return;

    // Filter out relayed addresses, only keep direct ones (TCP/IP)
    final directAddrs = addrs.where((addr) => !addr.toString().contains('p2p-circuit')).toList();

    // Try to dial all addresses in parallel
    for (final addr in directAddrs) {
        try {
            await host.connect(addr);
            // If successful, Libp2pHost will register a new DIRECT connection
            // which will be preferred over the RELAYED one by ConnectionManager
            return; 
        } catch (_) {
            // Continue to next address
        }
    }
  }

  Uint8List _encodeMessage(_DcutrMessage message) {
    return Uint8List.fromList([
      ...protoEnum(1, message.type.code),
      for (final addr in message.addrs) ...protoBytes(2, addr.toBytes()),
    ]);
  }

  _DcutrMessage _decodeMessage(Uint8List bytes) {
    var type = _DcutrMessageType.connect;
    final addrs = <Multiaddr>[];
    var offset = 0;
    while (offset < bytes.length) {
      final field = _readVarint(bytes, offset);
      offset += field.length;
      final fieldNumber = field.value >> 3;
      final wireType = field.value & 0x07;
      if (wireType == 0) {
        final val = _readVarint(bytes, offset);
        offset += val.length;
        if (fieldNumber == 1) {
          type = _DcutrMessageType.values.firstWhere((e) => e.code == val.value);
        }
      } else if (wireType == 2) {
        final len = _readVarint(bytes, offset);
        offset += len.length;
        final content = bytes.sublist(offset, offset + len.value);
        offset += len.value;
        if (fieldNumber == 2) addrs.add(Multiaddr.fromBytes(content));
      }
    }
    return _DcutrMessage(type: type, addrs: addrs);
  }

  // Internal helpers
  _VarintResult _readVarint(Uint8List bytes, int offset) {
    var shift = 0;
    var value = 0;
    var index = offset;
    while (index < bytes.length) {
      final byte = bytes[index];
      value |= (byte & 0x7f) << shift;
      index++;
      if ((byte & 0x80) == 0) return _VarintResult(value, index - offset);
      shift += 7;
    }
    throw const FormatException('incomplete varint');
  }
}

class _VarintResult {
  _VarintResult(this.value, this.length);
  final int value;
  final int length;
}
