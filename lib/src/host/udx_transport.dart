import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../address/multiaddr.dart';
import '../core/connection_io.dart';
import '../core/transport.dart';

/// UDX Transport implementation for libp2p.
/// UDX is a UDP-based, reliable, multiplexed transport.
class UdxTransport implements Transport {
  final Map<int, StreamController<UdxConnection>> _listeners = {};

  @override
  bool canDial(Multiaddr address) {
    return address.valueForProtocol('udx') != null || 
           (address.valueForProtocol('udp') != null && address.valueForProtocol('quic') == null);
  }

  @override
  Future<ConnectionListener> listen(Multiaddr address) async {
    final host = address.valueForProtocol('ip4') ?? '0.0.0.0';
    final portStr = address.valueForProtocol('udp') ?? address.valueForProtocol('udx') ?? '0';
    final port = int.parse(portStr);

    final socket = await RawDatagramSocket.bind(host, port);
    final controller = StreamController<ConnectionIO>.broadcast();

    final actualAddress = Multiaddr([
      ...address.components.where((c) => c.protocol != 'udp' && c.protocol != 'udx'),
      MultiaddrComponent('udx', socket.port.toString()),
    ]);

    final sessions = <String, UdxConnection>{};

    socket.listen((event) {
      if (event == RawDatagramSocketUint8List.readEvent) {
        final dg = socket.receive();
        if (dg != null) {
          final sessionKey = '${dg.address.address}:${dg.port}';
          var session = sessions[sessionKey];
          if (session == null) {
            session = UdxConnection(socket, dg.address.address, dg.port, isPassive: true);
            sessions[sessionKey] = session;
            controller.add(session);
          }
          session._addIncoming(dg.data);
        }
      }
    });

    return UdxListener(actualAddress, controller.stream, socket);
  }

  @override
  Future<ConnectionIO> dial(Multiaddr address) async {
    final host = address.valueForProtocol('ip4') ?? '127.0.0.1';
    final portStr = address.valueForProtocol('udp') ?? address.valueForProtocol('udx');
    if (portStr == null) throw ArgumentError('UDX address must contain a port');
    
    final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    return UdxConnection(socket, host, int.parse(portStr));
  }
}

class UdxListener implements ConnectionListener {
  UdxListener(this.address, this.incoming, this.socket);

  @override
  final Multiaddr address;
  @override
  final Stream<ConnectionIO> incoming;
  final RawDatagramSocket socket;

  @override
  Future<void> close() async {
    socket.close();
  }
}

class UdxConnection implements ConnectionIO {
  UdxConnection(this.socket, this.remoteHost, this.remotePort, {this.isPassive = false})
      : _incomingController = StreamController<Uint8List>() {
    if (!isPassive) {
      socket.listen((event) {
        if (event == RawDatagramSocketUint8List.readEvent) {
          final dg = socket.receive();
          if (dg != null) {
            _addIncoming(dg.data);
          }
        }
      });
    }
  }

  final RawDatagramSocket socket;
  final String remoteHost;
  final int remotePort;
  final bool isPassive;
  final StreamController<Uint8List> _incomingController;

  void _addIncoming(Uint8List bytes) {
    if (!_incomingController.isClosed) {
      _incomingController.add(bytes);
    }
  }

  @override
  Stream<Uint8List> get input => _incomingController.stream;

  @override
  late final ByteReader reader = ByteReader(input);

  @override
  void send(Uint8List bytes) {
    socket.send(bytes, InternetAddress(remoteHost), remotePort);
  }

  @override
  Future<void> close() async {
    await _incomingController.close();
    socket.close();
  }
}

// Extension to help with RawDatagramSocket events in newer Dart versions if needed
class RawDatagramSocketUint8List {
  static const readEvent = RawSocketEvent.read;
}
