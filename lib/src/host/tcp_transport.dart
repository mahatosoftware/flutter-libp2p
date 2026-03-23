import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../address/multiaddr.dart';
import '../core/connection_io.dart';
import '../core/transport.dart';

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
  late final Stream<Uint8List> input = _incomingController.stream;
  @override
  late final ByteReader reader = ByteReader(input);

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

class TcpListener implements ConnectionListener {
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

  @override
  Stream<RawConnection> get incoming => _incomingController.stream;

  @override
  Multiaddr get address => Multiaddr.parse(
    '/ip4/${serverSocket.address.address}/tcp/${serverSocket.port}',
  );

  @override
  Future<void> close() async {
    await _subscription.cancel();
    await serverSocket.close();
  }
}

class TcpTransport implements Transport {
  @override
  bool canDial(Multiaddr address) {
    return address.valueForProtocol('tcp') != null;
  }

  @override
  Future<TcpListener> listen(Multiaddr address) async {
    final host = address.valueForProtocol('ip4') ?? '0.0.0.0';
    final port = int.parse(address.valueForProtocol('tcp') ?? '0');
    final serverSocket = await ServerSocket.bind(host, port);
    return TcpListener(serverSocket);
  }

  @override
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
