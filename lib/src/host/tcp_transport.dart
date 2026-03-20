import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../address/multiaddr.dart';
import '../core/connection_io.dart';

class RawConnection implements ConnectionIO {
  RawConnection(this.socket)
    : _incomingController = StreamController<Uint8List>.broadcast() {
    _subscription = socket.listen(
      (data) => _incomingController.add(Uint8List.fromList(data)),
      onDone: () => _incomingController.close(),
      onError: (Object error, StackTrace stackTrace) {
        _incomingController.addError(error, stackTrace);
        _incomingController.close();
      },
      cancelOnError: false,
    );
  }

  final Socket socket;
  late final StreamSubscription<List<int>> _subscription;
  final StreamController<Uint8List> _incomingController;
  @override
  late final ByteReader reader = ByteReader(_incomingController.stream);

  @override
  void send(Uint8List bytes) => socket.add(bytes);

  @override
  Future<void> close() async {
    await _subscription.cancel();
    await socket.close();
  }

  Multiaddr get remoteAddress => Multiaddr.parse(
    '/ip4/${socket.remoteAddress.address}/tcp/${socket.remotePort}',
  );
}

class TcpListener {
  TcpListener(this.serverSocket)
    : _incomingController = StreamController<RawConnection>.broadcast() {
    _subscription = serverSocket.listen(
      (socket) => _incomingController.add(RawConnection(socket)),
      onDone: () => _incomingController.close(),
      onError: (Object error, StackTrace stackTrace) {
        _incomingController.addError(error, stackTrace);
        _incomingController.close();
      },
      cancelOnError: false,
    );
  }

  final ServerSocket serverSocket;
  final StreamController<RawConnection> _incomingController;
  late final StreamSubscription<Socket> _subscription;

  Stream<RawConnection> get incoming => _incomingController.stream;

  Multiaddr get address => Multiaddr.parse(
    '/ip4/${serverSocket.address.address}/tcp/${serverSocket.port}',
  );

  Future<void> close() async {
    await _subscription.cancel();
    await serverSocket.close();
  }
}

class TcpTransport {
  Future<TcpListener> listen({
    String host = '0.0.0.0',
    required int port,
  }) async {
    final serverSocket = await ServerSocket.bind(host, port);
    return TcpListener(serverSocket);
  }

  Future<RawConnection> dial(Multiaddr address) async {
    final host =
        address.valueForProtocol('ip4') ??
        address.valueForProtocol('dns4') ??
        address.valueForProtocol('dns6') ??
        address.valueForProtocol('dnsaddr');
    final port = address.valueForProtocol('tcp');
    if (host == null || port == null) {
      throw ArgumentError('TCP multiaddr must contain host and port');
    }

    final socket = await Socket.connect(host, int.parse(port));
    return RawConnection(socket);
  }
}
