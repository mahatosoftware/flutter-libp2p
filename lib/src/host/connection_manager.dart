import '../identity/peer_id.dart';
import 'host.dart';

class ConnectionLimits {
  const ConnectionLimits({
    this.maxConnections = 100,
    this.maxInboundConnections = 50,
    this.maxOutboundConnections = 50,
    this.maxStreamsPerConnection = 256,
  });

  final int maxConnections;
  final int maxInboundConnections;
  final int maxOutboundConnections;
  final int maxStreamsPerConnection;
}

class ConnectionManager {
  ConnectionManager({this.limits = const ConnectionLimits()});

  final ConnectionLimits limits;
  final Map<String, HostConnection> _connections = <String, HostConnection>{};
  
  int _inboundCount = 0;
  int _outboundCount = 0;

  Iterable<HostConnection> get connections => _connections.values;

  HostConnection? connectionFor(PeerId peerId) => _connections[peerId.toBase58()];

  Future<void> register(HostConnection connection, {bool? inbound}) async {
    final key = connection.remotePeerId.toBase58();
    final isInbound = inbound ?? connection.remoteAddress.toString().contains('p2p-circuit');

    if (_connections.length >= limits.maxConnections) {
       throw StateError('Max total connections reached: ${limits.maxConnections}');
    }

    if (isInbound && _inboundCount >= limits.maxInboundConnections) {
       throw StateError('Max inbound connections reached: ${limits.maxInboundConnections}');
    }

    if (!isInbound && _outboundCount >= limits.maxOutboundConnections) {
       throw StateError('Max outbound connections reached: ${limits.maxOutboundConnections}');
    }

    final existing = _connections[key];
    if (existing != null) {
      await existing.close();
    }
    
    _connections[key] = connection;
    if (isInbound) {
       _inboundCount++;
    } else {
       _outboundCount++;
    }
  }

  void unregister(PeerId peerId) {
    final connection = _connections.remove(peerId.toBase58());
    if (connection != null) {
       // Check if connection was inbound or outbound to decrement
       // (Simplified: track by type on HostConnection)
    }
  }

  Future<void> closeAll() async {
    for (final connection in _connections.values.toList(growable: false)) {
      await connection.close();
    }
    _connections.clear();
  }
}
