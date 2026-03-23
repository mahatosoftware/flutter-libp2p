import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_libp2p/src/address/multiaddr.dart';
import 'package:flutter_libp2p/src/core/connection_io.dart';
import 'package:flutter_libp2p/src/core/transport.dart';
import 'package:flutter_libp2p/src/host/tcp_transport.dart';

class MockTcpTransport implements Transport {
  final _listeners = <String, StreamController<ConnectionIO>>{};

  @override
  bool canDial(Multiaddr address) {
    return address.valueForProtocol('tcp') != null;
  }

  @override
  Future<ConnectionListener> listen(Multiaddr address) async {
    final host = address.valueForProtocol('ip4') ?? '0.0.0.0';
    final port = address.valueForProtocol('tcp')!;
    final key = '$host:$port';
    if (_listeners.containsKey(key)) throw StateError('port already in use');
    
    final controller = StreamController<ConnectionIO>.broadcast();
    _listeners[key] = controller;
    
    return MockTcpListener(
      Multiaddr([MultiaddrComponent('ip4', host), MultiaddrComponent('tcp', port)]),
      controller.stream,
      () => _listeners.remove(key),
    );
  }

  @override
  Future<ConnectionIO> dial(Multiaddr address) async {
    final host = address.valueForProtocol('ip4') ?? '0.0.0.0';
    final port = address.valueForProtocol('tcp')!;
    final key = '$host:$port';
    
    final listener = _listeners[key];
    if (listener == null) throw StateError('could not connect to $key');
    
    final clientToHost = StreamController<Uint8List>.broadcast();
    final hostToClient = StreamController<Uint8List>.broadcast();
    
    final clientConn = MockRawConnection(
      localAddress: Multiaddr([MultiaddrComponent('ip4', '127.0.0.1'), MultiaddrComponent('tcp', '0')]),
      remoteAddress: address,
      input: hostToClient.stream,
      output: clientToHost,
    );
    
    final hostConn = MockRawConnection(
      localAddress: address,
      remoteAddress: clientConn.localAddress,
      input: clientToHost.stream,
      output: hostToClient,
    );
    
    listener.add(hostConn);
    return clientConn;
  }
}

class MockTcpListener implements ConnectionListener {
  MockTcpListener(this.address, this.incoming, this._onClose);
  @override
  final Multiaddr address;
  @override
  final Stream<ConnectionIO> incoming;
  final void Function() _onClose;

  @override
  Future<void> close() async {
    _onClose();
  }
}

class MockRawConnection implements ConnectionIO {
  MockRawConnection({required this.localAddress, required this.remoteAddress, required this.input, required this.output});
  
  final Multiaddr localAddress;
  final Multiaddr remoteAddress;
  @override
  final Stream<Uint8List> input;
  final StreamController<Uint8List> output;

  @override
  late final ByteReader reader = ByteReader(input);

  @override
  void send(Uint8List bytes) => output.add(bytes);

  @override
  Future<void> close() async {
    await output.close();
  }
}
