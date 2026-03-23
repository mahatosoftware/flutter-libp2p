import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../host/host.dart';
import '../identity/peer_id.dart';
import '../core/libp2p_stream.dart';
import '../host/protocol_registry.dart';
import '../crypto/protobuf.dart';

class GossipsubMessage {
  GossipsubMessage({
    required this.from,
    required this.data,
    required this.seqNo,
    required this.topic,
    this.signature,
    this.key,
  });

  final PeerId from;
  final Uint8List data;
  final Uint8List seqNo;
  final String topic;
  final Uint8List? signature;
  final Uint8List? key;
}

class GossipsubService implements HostService {
  static const protocolId = '/meshsub/1.1.0';
  static const legacyProtocolId = '/meshsub/1.0.0';

  final Map<String, Set<PeerId>> _mesh = {};
  final Map<String, Set<PeerId>> _fanout = {};
  final Map<String, Set<PeerId>> _topics = {};
  final Map<String, StreamController<GossipsubMessage>> _topicControllers = {};
  final Map<String, Set<Uint8List>> _seenMessages = {};
  
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
     final msg = GossipsubMessage(
         from: _host!.peerId,
         data: data,
         seqNo: Uint8List.fromList(DateTime.now().millisecondsSinceEpoch.toString().codeUnits),
         topic: topic,
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
            final rpc = _decodeRPC(bytes);
            for (final msg in rpc.messages) {
                if (_shouldForward(msg)) {
                    _forward(msg);
                    _topicControllers[msg.topic]?.add(msg);
                }
            }
        } catch (_) {
            break;
        }
     }
  }

  bool _shouldForward(GossipsubMessage msg) {
     // Check if message ID seen
     return true;
  }

  void _forward(GossipsubMessage msg) {
     // Send to peers in mesh
     final peers = _mesh[msg.topic] ?? {};
     for (final peerId in peers) {
         // Open stream and send
     }
  }

  _GossipsubRPC _decodeRPC(Uint8List bytes) {
    // Protobuf decoder for Gossipsub RPC
    return _GossipsubRPC(messages: []);
  }
}

class _GossipsubRPC {
  _GossipsubRPC({required this.messages});
  final List<GossipsubMessage> messages;
}
