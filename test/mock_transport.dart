import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_libp2p/src/address/multiaddr.dart';
import 'package:flutter_libp2p/src/core/connection_io.dart';
import 'package:flutter_libp2p/src/host/tcp_transport.dart';

class MockTcpTransport implements TcpTransport {
  final _listeners = <String, StreamController<RawConnection>>{};

  @override
  Future<TcpListener> listen({String host = '0.0.0.0', required int port}) async {
    final key = '$host:$port';
    if (_listeners.containsKey(key)) throw StateError('port already in use');
    
    final controller = StreamController<RawConnection>.broadcast();
    _listeners[key] = controller;
    
    return MockTcpListener(
      Multiaddr([MultiaddrComponent('ip4', host), MultiaddrComponent('tcp', port.toString())]),
      controller.stream,
      () => _listeners.remove(key),
    );
  }

  @override
  Future<RawConnection> dial(Multiaddr address) async {
    final host = address.valueForProtocol('ip4') ?? '0.0.0.0';
    final port = address.valueForProtocol('tcp')!;
    final key = '$host:$port';
    
    final listener = _listeners[key];
    if (listener == null) throw StateError('could not connect to $key');
    
    final clientToHost = StreamController<Uint8List>.broadcast();
    final hostToClient = StreamController<Uint8List>.broadcast();
    
    final clientConn = MockRawConnection(
      local: Multiaddr([MultiaddrComponent('ip4', '127.0.0.1'), MultiaddrComponent('tcp', '0')]),
      remote: address,
      input: hostToClient.stream,
      output: clientToHost,
    );
    
    final hostConn = MockRawConnection(
      local: address,
      remote: clientConn.localAddress,
      input: clientToHost.stream,
      output: hostToClient,
    );
    
    listener.add(hostConn);
    return clientConn;
  }
}

class MockTcpListener implements TcpListener {
  MockTcpListener(this.address, this.incoming, this._onClose);
  final Multiaddr address;
  final Stream<RawConnection> incoming;
  final void Function() _onClose;

  @override
  Future<void> close() async {
    _onClose();
  }
}

class MockRawConnection implements RawConnection {
  MockRawConnection({required this.localAddress, required this.remoteAddress, required this.input, required this.output});
  final Multiaddr localAddress;
  final Multiaddr remoteAddress;
  final Stream<Uint8List> input;
  final StreamController<Uint8List> output;

  @override
  Future<void> write(Uint8List data) async {
    output.add(data);
  }

  @override
  Future<void> close() async {
    await output.close();
  }
}
