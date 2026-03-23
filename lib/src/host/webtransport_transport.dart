import 'dart:async';
import 'dart:typed_data';

import '../address/multiaddr.dart';
import '../core/connection_io.dart';
import '../core/transport.dart';

import '../core/muxer.dart';
import '../core/libp2p_stream.dart';

class WebTransportConnection implements ConnectionIO, StreamMuxer {
  WebTransportConnection()
    : _incomingController = StreamController<Uint8List>.broadcast(),
      _incomingStreamsController = StreamController<Libp2pStream>.broadcast() {
    // In a real WebTransport implementation, this is backed by WebTransport bidir streams
  }

  final StreamController<Uint8List> _incomingController;
  final StreamController<Libp2pStream> _incomingStreamsController;

  @override
  late final Stream<Uint8List> input = _incomingController.stream;
  @override
  late final ByteReader reader = ByteReader(input);

  @override
  Stream<Libp2pStream> get incomingStreams => _incomingStreamsController.stream;

  @override
  Future<Libp2pStream> openStream([String name = 'stream']) async {
    // In WebTransport, we would create a new bidirectional stream
    return Libp2pStream(this);
  }

  @override
  void send(Uint8List bytes) {
    // WebTransportStream.getWriter().write(bytes)
  }

  @override
  Future<void> close() async {
    await _incomingController.close();
    await _incomingStreamsController.close();
  }
}

class WebTransportListener implements ConnectionListener {
  WebTransportListener()
    : _incomingController = StreamController<WebTransportConnection>.broadcast() {
    // WebTransport usually requires an HTTPS server or similar in some environments
  }

  final StreamController<WebTransportConnection> _incomingController;

  @override
  Stream<WebTransportConnection> get incoming => _incomingController.stream;

  @override
  Multiaddr get address => Multiaddr.parse('/webtransport');

  @override
  Future<void> close() async {
    await _incomingController.close();
  }
}

class WebTransportTransport implements Transport {
  @override
  bool canDial(Multiaddr address) {
    return address.valueForProtocol('webtransport') != null;
  }

  @override
  Future<WebTransportListener> listen(Multiaddr address) async {
    return WebTransportListener();
  }

  @override
  Future<WebTransportConnection> dial(Multiaddr address) async {
    // Initializing a WebTransport connection
    return WebTransportConnection();
  }
}
