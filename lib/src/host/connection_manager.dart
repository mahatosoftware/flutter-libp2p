import '../identity/peer_id.dart';
import 'host.dart';

class ConnectionManager {
  ConnectionManager({this.maxConnections = 64});

  final int maxConnections;
  final Map<String, HostConnection> _connections = <String, HostConnection>{};

  Iterable<HostConnection> get connections => _connections.values;

  HostConnection? connectionFor(PeerId peerId) => _connections[peerId.toBase58()];

  Future<void> register(HostConnection connection) async {
    final key = connection.remotePeerId.toBase58();
    final existing = _connections[key];
    if (existing != null) {
      await existing.close();
    }
    _connections[key] = connection;

    if (_connections.length > maxConnections) {
      final oldest = _connections.values.reduce(
        (current, next) => current.createdAt.isBefore(next.createdAt) ? current : next,
      );
      await oldest.close();
      _connections.remove(oldest.remotePeerId.toBase58());
    }
  }

  void unregister(PeerId peerId) {
    _connections.remove(peerId.toBase58());
  }

  Future<void> closeAll() async {
    for (final connection in _connections.values.toList(growable: false)) {
      await connection.close();
    }
    _connections.clear();
  }
}
