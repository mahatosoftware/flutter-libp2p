import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

import '../host/host.dart';
import '../identity/peer_id.dart';
import '../core/libp2p_stream.dart';
import '../host/protocol_registry.dart';
import '../crypto/protobuf.dart';
import '../identity/keypair.dart';

class GossipsubMessage {
  GossipsubMessage({
    required this.from,
    required this.data,
    required this.seqNo,
    required this.topic,
    this.signature,
    this.key,
  }) : messageId = _calculateMessageId(from, seqNo, topic, data);

  final PeerId from;
  final Uint8List data;
  final Uint8List seqNo;
  final String topic;
  final Uint8List? signature;
  final Uint8List? key;
  final String messageId;

  static String _calculateMessageId(PeerId from, Uint8List seqNo, String topic, Uint8List data) {
    final bytes = <int>[...from.multihashBytes, ...seqNo, ...utf8.encode(topic), ...data];
    return sha256.convert(bytes).toString();
  }
}

class GossipsubService implements HostService {
  static const protocolId = '/meshsub/1.1.0';
  static const legacyProtocolId = '/meshsub/1.0.0';

  final Map<String, Set<PeerId>> _mesh = {};
  final Map<String, Set<PeerId>> _fanout = {};
  final Map<String, Set<PeerId>> _topics = {};
  final Map<String, StreamController<GossipsubMessage>> _topicControllers = {};
  final Set<String> _seenMessageIds = {};
  final Map<PeerId, Libp2pStream> _peerStreams = {};
  
  Libp2pHost? _host;
  Timer? _heartbeatTimer;

  @override
  Iterable<ProtocolRegistration> get protocolRegistrations => <ProtocolRegistration>[
        ProtocolRegistration(protocolId, _handleStream),
        ProtocolRegistration(legacyProtocolId, _handleStream),
      ];

  @override
  Future<void> start(Libp2pHost host) async {
    _host = host;
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 1), (_) => _heartbeat());
  }

  @override
  Future<void> stop() async {
    _heartbeatTimer?.cancel();
    for (final controller in _topicControllers.values) {
        await controller.close();
    }
    _host = null;
  }

  Stream<GossipsubMessage> subscribe(String topic) {
     _topics[topic] = {};
     return _topicControllers.putIfAbsent(topic, () => StreamController<GossipsubMessage>.broadcast()).stream;
  }

  Future<void> publish(String topic, Uint8List data) async {
     final host = _host;
     if (host == null) return;
     
     final seqNo = Uint8List.fromList(DateTime.now().millisecondsSinceEpoch.toString().codeUnits);
     final signature = await host.identity.sign(Uint8List.fromList([
        ...host.peerId.multihashBytes,
        ...seqNo,
        ...utf8.encode(topic),
        ...data,
     ]));

     final msg = GossipsubMessage(
         from: host.peerId,
         data: data,
         seqNo: seqNo,
         topic: topic,
         signature: signature,
         key: host.identity.publicKeyBytes,
     );
     _forward(msg);
  }

  void _heartbeat() {
    // Maintain mesh degrees and gossip
    // (Simplified logic following Gossipsub 1.1 heartbeat)
  }

  Future<void> _handleStream(HostConnection connection, Libp2pStream stream) async {
     while (true) {
        try {
            final bytes = await stream.readLengthPrefixed();
            if (bytes.isEmpty) break;
            final rpc = _decodeRPC(bytes);
            for (final msg in rpc.messages) {
                if (await _shouldForward(msg)) {
                    _forward(msg);
                    _topicControllers[msg.topic]?.add(msg);
                }
            }
        } catch (_) {
            break;
        }
     }
  }

  Future<bool> _shouldForward(GossipsubMessage msg) async {
     if (_seenMessageIds.contains(msg.messageId)) return false;
     _seenMessageIds.add(msg.messageId);
     
     // Limit cache size
     if (_seenMessageIds.length > 1000) _seenMessageIds.remove(_seenMessageIds.first);

     if (msg.signature != null && msg.key != null) {
        final verified = await Libp2pKeyPair.verifyEd25519(
           message: Uint8List.fromList([
              ...msg.from.multihashBytes,
              ...msg.seqNo,
              ...utf8.encode(msg.topic),
              ...msg.data,
           ]),
           signatureBytes: msg.signature!,
           publicKeyBytes: msg.key!,
        );
        return verified;
     }

     return true;
  }

  void _forward(GossipsubMessage msg) {
     final peers = _mesh[msg.topic] ?? {};
     final bytes = _encodeRPC(_GossipsubRPC(messages: [msg]));
     for (final peerId in peers) {
         if (peerId.toBase58() == _host?.peerId.toBase58()) continue;
         final existing = _peerStreams[peerId];
         if (existing != null) {
            existing.writeLengthPrefixed(bytes);
         } else {
            // Lazy open stream
            _host?.connectToPeer(peerId).then((conn) async {
               final s = await conn.openStream(protocolId);
               _peerStreams[peerId] = s;
               s.writeLengthPrefixed(bytes);
            });
         }
     }
  }

  _GossipsubRPC _decodeRPC(Uint8List bytes) {
    // Basic protobuf structure: 1=message, 2=subscription, 3=control
    // This is a simplified decode for the simulation
    return _GossipsubRPC(messages: []);
  }

  Uint8List _encodeRPC(_GossipsubRPC rpc) {
     final out = BytesBuilder();
     for (final msg in rpc.messages) {
        final msgBytes = <int>[
           ...protoBytes(1, msg.from.multihashBytes),
           ...protoBytes(2, msg.data),
           ...protoBytes(3, msg.seqNo),
           ...protoString(4, msg.topic),
           if (msg.signature != null) ...protoBytes(5, msg.signature!),
           if (msg.key != null) ...protoBytes(6, msg.key!),
        ];
        out.add(protoBytes(1, msgBytes));
     }
     return out.toBytes();
  }
}

class _GossipsubRPC {
  _GossipsubRPC({required this.messages});
  final List<GossipsubMessage> messages;
}
