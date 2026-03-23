import '../address/multiaddr.dart';
import 'connection_io.dart';

abstract interface class ConnectionListener {
  Stream<ConnectionIO> get incoming;
  Multiaddr get address;
  Future<void> close();
}

abstract interface class Transport {
  bool canDial(Multiaddr address);
  Future<ConnectionIO> dial(Multiaddr address);
  Future<ConnectionListener> listen(Multiaddr address);
}
