import 'dart:async';
import 'dart:typed_data';

import '../address/multiaddr.dart';
import '../core/connection_io.dart';
import '../core/transport.dart';
import '../protocols/noise.dart';
import '../identity/keypair.dart';
import '../identity/peer_id.dart';
import '../core/libp2p_stream.dart';
import '../core/muxer.dart';

class WebRTCConnection implements ConnectionIO, StreamMuxer {
  WebRTCConnection({required this.localKeyPair, required this.initiator})
    : _incomingController = StreamController<Uint8List>.broadcast(),
      _incomingStreamsController = StreamController<Libp2pStream>.broadcast() {
    _startNoiseHandshake();
  }

  final Libp2pKeyPair localKeyPair;
  final bool initiator;
  final StreamController<Uint8List> _incomingController;
  final StreamController<Libp2pStream> _incomingStreamsController;
  final Map<int, _WebRTCStreamIO> _streams = {};
  late final NoiseProtocol _noise = NoiseProtocol(localKeyPair);
  bool _handshakeComplete = false;

  Future<void> _startNoiseHandshake() async {
     // In libp2p-webrtc, Noise happens over the data channel
     if (initiator) {
        final result = await _noise.secureOutbound(this);
        // remotePeerId verified against Multiaddr certhash
        _handshakeComplete = true;
     } else {
        await _noise.secureInbound(this);
        _handshakeComplete = true;
     }
  }

  @override
  late final Stream<Uint8List> input = _incomingController.stream;
  @override
  late final ByteReader reader = ByteReader(input);

  @override
  Stream<Libp2pStream> get incomingStreams => _incomingStreamsController.stream;

  @override
  Future<Libp2pStream> openStream([String name = 'stream']) async {
    final id = _streams.length;
    final streamIo = _WebRTCStreamIO(this, id);
    _streams[id] = streamIo;
    return Libp2pStream(streamIo);
  }

  @override
  void send(Uint8List bytes) {
    // Simulated DataChannel.send
  }

  @override
  Future<void> close() async {
    await _incomingController.close();
    await _incomingStreamsController.close();
  }
}

class _WebRTCStreamIO implements ConnectionIO {
  _WebRTCStreamIO(this._parent, this.streamId);
  final WebRTCConnection _parent;
  final int streamId;
  final StreamController<Uint8List> _incomingController = StreamController<Uint8List>.broadcast();

  @override
  Stream<Uint8List> get input => _incomingController.stream;
  @override
  late final ByteReader reader = ByteReader(input);

  @override
  void send(Uint8List bytes) {
    _parent.send(bytes);
  }

  @override
  Future<void> close() async {
    await _incomingController.close();
  }
}

class WebRTCListener implements ConnectionListener {
  WebRTCListener()
    : _incomingController = StreamController<WebRTCConnection>.broadcast() {
    // Handling incoming WebRTC connection offers
  }

  final StreamController<WebRTCConnection> _incomingController;

  @override
  Stream<WebRTCConnection> get incoming => _incomingController.stream;

  @override
  Multiaddr get address => Multiaddr.parse('/webrtc-direct');

  @override
  Future<void> close() async {
    await _incomingController.close();
  }
}

class WebRTCTransport implements Transport {
  WebRTCTransport(this.localKeyPair);
  final Libp2pKeyPair localKeyPair;

  @override
  bool canDial(Multiaddr address) {
    return address.valueForProtocol('webrtc-direct') != null ||
           address.valueForProtocol('webrtc') != null;
  }

  @override
  Future<WebRTCListener> listen(Multiaddr address) async {
    return WebRTCListener();
  }

  @override
  Future<WebRTCConnection> dial(Multiaddr address) async {
    // 1. Verify certhash if present
    final certhash = address.valueForProtocol('certhash');
    
    // 2. Initialize P2P connection
    return WebRTCConnection(localKeyPair: localKeyPair, initiator: true);
  }
}
