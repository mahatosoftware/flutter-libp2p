import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../address/multiaddr.dart';
import '../core/connection_io.dart';
import '../core/transport.dart';

import '../core/muxer.dart';
import '../core/libp2p_stream.dart';

class QuicConnection implements ConnectionIO, StreamMuxer {
  QuicConnection(this.socket, this.remoteAddress, this.remotePort, {required this.initiator})
    : _incomingController = StreamController<Uint8List>.broadcast(),
      _incomingStreamsController = StreamController<Libp2pStream>.broadcast() {
    _startHandshake();
  }

  final RawDatagramSocket socket;
  final InternetAddress remoteAddress;
  final int remotePort;
  final bool initiator;
  final StreamController<Uint8List> _incomingController;
  final StreamController<Libp2pStream> _incomingStreamsController;
  final Map<int, _QuicStreamIO> _streams = {};
  bool _handshakeComplete = false;
  
  void _startHandshake() {
    if (initiator) {
      // Send Initial packet (simulated)
      _sendPacket(Uint8List.fromList([0xC0, 0x00, 0x00, 0x01, ...utf8.encode('QUIC-INITIAL')]));
    }
  }

  void handlePacket(Uint8List packet) {
    if (!_handshakeComplete) {
       // Simple handshake state machine
       _handshakeComplete = true;
       return;
    }
    // Handle data packets and route to streams
  }

  void _sendPacket(Uint8List data) {
    socket.send(data, remoteAddress, remotePort);
  }

  @override
  late final Stream<Uint8List> input = _incomingController.stream;
  @override
  late final ByteReader reader = ByteReader(input);

  @override
  Stream<Libp2pStream> get incomingStreams => _incomingStreamsController.stream;

  @override
  Future<Libp2pStream> openStream([String name = 'stream']) async {
    final id = _streams.length * 4 + (initiator ? 0 : 1);
    final streamIo = _QuicStreamIO(this, id);
    _streams[id] = streamIo;
    return Libp2pStream(streamIo);
  }

  @override
  void send(Uint8List bytes) {
    _sendPacket(bytes);
  }

  @override
  Future<void> close() async {
    await _incomingController.close();
    await _incomingStreamsController.close();
  }
}

class _QuicStreamIO implements ConnectionIO {
  _QuicStreamIO(this._parent, this.streamId);
  final QuicConnection _parent;
  final int streamId;
  final StreamController<Uint8List> _incomingController = StreamController<Uint8List>.broadcast();

  @override
  Stream<Uint8List> get input => _incomingController.stream;
  @override
  late final ByteReader reader = ByteReader(input);

  @override
  void send(Uint8List bytes) {
    // Encapsulate in QUIC Stream frame
    _parent._sendPacket(bytes);
  }

  @override
  Future<void> close() async {
    await _incomingController.close();
  }
}

class QuicListener implements ConnectionListener {
   QuicListener(this.socket)
    : _incomingController = StreamController<QuicConnection>.broadcast() {
    socket.listen((event) {
      if (event == RawSocketEvent.read) {
        final dg = socket.receive();
        if (dg != null) {
          final conn = _getConnectionFor(dg.address, dg.port);
          conn.handlePacket(dg.data);
        }
      }
    });
  }

  final RawDatagramSocket socket;
  final StreamController<QuicConnection> _incomingController;
  final Map<String, QuicConnection> _connections = {};

  QuicConnection _getConnectionFor(InternetAddress addr, int port) {
    final key = '${addr.address}:$port';
    return _connections.putIfAbsent(key, () {
      final conn = QuicConnection(socket, addr, port, initiator: false);
      _incomingController.add(conn);
      return conn;
    });
  }

  @override
  Stream<QuicConnection> get incoming => _incomingController.stream;

  @override
  Multiaddr get address => Multiaddr.parse(
    '/ip4/${socket.address.address}/udp/${socket.port}/quic-v1',
  );

  @override
  Future<void> close() async {
    await _incomingController.close();
    socket.close();
  }
}

class QuicTransport implements Transport {
  @override
  bool canDial(Multiaddr address) {
    return address.valueForProtocol('quic') != null || 
           address.valueForProtocol('quic-v1') != null;
  }

  @override
  Future<QuicListener> listen(Multiaddr address) async {
    final host = address.valueForProtocol('ip4') ?? '0.0.0.0';
    final port = int.parse(address.valueForProtocol('udp') ?? '0');
    final socket = await RawDatagramSocket.bind(host, port);
    return QuicListener(socket);
  }

  @override
  Future<QuicConnection> dial(Multiaddr address) async {
    final host = address.valueForProtocol('ip4') ??
                address.valueForProtocol('dns4') ??
                address.valueForProtocol('dns6') ??
                address.valueForProtocol('dnsaddr');
    final udpPort = address.valueForProtocol('udp');
    
    if (host == null || udpPort == null) {
      throw ArgumentError('QUIC multiaddr must contain host and udp port');
    }

    final remoteAddr = (await InternetAddress.lookup(host)).first;
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    
    return QuicConnection(socket, remoteAddr, int.parse(udpPort), initiator: true);
  }
}
