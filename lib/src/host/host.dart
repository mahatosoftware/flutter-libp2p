import 'dart:async';

import '../address/multiaddr.dart';
import '../core/connection_io.dart';
import '../core/libp2p_stream.dart';
import '../identity/keypair.dart';
import '../identity/peer_id.dart';
import '../protocols/kad_dht.dart';
import '../protocols/identify.dart';
import '../protocols/mplex.dart';
import '../protocols/multistream_select.dart';
import '../protocols/noise.dart';
import '../protocols/ping.dart';
import '../protocols/relay_v2.dart';
import '../protocols/dcutr.dart';
import 'connection_manager.dart';
import 'peer_store.dart';
import 'protocol_registry.dart';
import 'tcp_transport.dart';

class HostConnection {
  HostConnection({
    required this.host,
    required this.remotePeerId,
    required this.remoteAddress,
    required MplexConnection multiplexer,
  })  : _multiplexer = multiplexer,
        createdAt = DateTime.now(),
        lastActiveAt = DateTime.now();

  final Libp2pHost host;
  final PeerId remotePeerId;
  final Multiaddr remoteAddress;
  final DateTime createdAt;
  DateTime lastActiveAt;
  final MplexConnection _multiplexer;

  Future<Libp2pStream> openStream(String protocolId) async {
    lastActiveAt = DateTime.now();
    final stream = await _multiplexer.openStream(protocolId);
    await MultistreamSelect.negotiateInitiator(stream, protocolId);
    return stream;
  }

  Future<void> close() async {
    host.connectionManager.unregister(remotePeerId);
    host.peerStore.markDisconnected(remotePeerId);
    await _multiplexer.close();
  }
}

class Libp2pHost {
  Libp2pHost._({
    required this.identity,
    required this.peerId,
    required this.transport,
    required this.protocolVersion,
    required this.agentVersion,
    required this.peerStore,
    required this.connectionManager,
    required this.protocolRegistry,
    required this.kadDht,
    required this.relay,
    required this.dcutr,
  });

  final Libp2pKeyPair identity;
  final PeerId peerId;
  final TcpTransport transport;
  final String protocolVersion;
  final String agentVersion;
  final PeerStore peerStore;
  final ConnectionManager connectionManager;
  final ProtocolRegistry protocolRegistry;
  final KadDhtService kadDht;
  final RelayService relay;
  final DcutrProtocol dcutr;
  final List<Multiaddr> _listenAddrs = <Multiaddr>[];
  final List<TcpListener> _listeners = <TcpListener>[];

  static Future<Libp2pHost> create({
    Libp2pKeyPair? identity,
    TcpTransport? transport,
    String protocolVersion = '/flutter-libp2p/0.1.0',
    String agentVersion = 'flutter-libp2p/0.1.0',
    PeerStore? peerStore,
    ConnectionManager? connectionManager,
  }) async {
    final localIdentity = identity ?? await Libp2pKeyPair.generateEd25519();
    final peerId = PeerId.fromEd25519(localIdentity);
    final actualPeerStore = peerStore ?? PeerStore();
    final actualConnectionManager = connectionManager ?? ConnectionManager();
    final protocolRegistry = ProtocolRegistry();
    final kadDht = KadDhtService(actualPeerStore);
    final relay = RelayService(actualPeerStore);
    final dcutr = DcutrProtocol();
    final host = Libp2pHost._(
      identity: localIdentity,
      peerId: peerId,
      transport: transport ?? TcpTransport(),
      protocolVersion: protocolVersion,
      agentVersion: agentVersion,
      peerStore: actualPeerStore,
      connectionManager: actualConnectionManager,
      protocolRegistry: protocolRegistry,
      kadDht: kadDht,
      relay: relay,
      dcutr: dcutr,
    );
    await host._registerBuiltins();
    return host;
  }

  List<Multiaddr> get listenAddrs => List<Multiaddr>.unmodifiable(_listenAddrs);

  Set<String> get supportedProtocols => protocolRegistry.supportedProtocols;

  void handle(String protocolId, StreamHandler handler) {
    protocolRegistry.registerHandler(protocolId, handler);
  }

  Future<Multiaddr> listen({String host = '0.0.0.0', required int port}) async {
    final listener = await transport.listen(host: host, port: port);
    _listeners.add(listener);
    final listenAddress = Multiaddr([
      ...listener.address.components,
      MultiaddrComponent('p2p', peerId.toBase58()),
    ]);
    _listenAddrs.add(listenAddress);

    listener.incoming.listen((rawConnection) async {
      final connection = await _upgradeIncoming(rawConnection);
      await connectionManager.register(connection);
      peerStore.markConnected(connection.remotePeerId, connection.remoteAddress);
      kadDht.addPeer(connection.remotePeerId, addr: connection.remoteAddress);
      _serveIncomingStreams(connection);
    });

    return listenAddress;
  }

  Future<HostConnection> connect(Multiaddr address) async {
    final rawAddress = Multiaddr(
      address.components
          .where((component) => component.protocol != 'p2p')
          .toList(),
    );
    final rawConnection = await transport.dial(rawAddress);
    final connection = await _upgradeOutgoing(rawConnection, address);
    await connectionManager.register(connection);
    peerStore.markConnected(connection.remotePeerId, connection.remoteAddress);
    kadDht.addPeer(connection.remotePeerId, addr: connection.remoteAddress);
    _serveIncomingStreams(connection);

    if (connection.remoteAddress.toString().contains('p2p-circuit')) {
        unawaited(dcutr.attemptHolePunch(connection));
    }

    return connection;
  }

  Future<Duration> ping(HostConnection connection) async {
    final stream = await connection.openStream(PingProtocol.protocolId);
    return PingProtocol.ping(stream);
  }

  Future<IdentifySnapshot> identify(HostConnection connection) async {
    final stream = await connection.openStream(IdentifyProtocol.protocolId);
    return IdentifyProtocol.readMessage(stream);
  }

  Future<void> close() async {
    await protocolRegistry.stopAllServices();
    for (final listener in _listeners) {
      await listener.close();
    }
    await connectionManager.closeAll();
  }

  void handleRelayedStream(PeerId remotePeerId, Libp2pStream stream) {
    // Treat as any other incoming stream, but we already know the remote peer id
    // We might want to wrap it in a pseudo-connection
    _serveNegotiatedStream(remotePeerId, stream);
  }

  Future<void> _registerBuiltins() async {
    handle(PingProtocol.protocolId, (connection, stream) {
      return PingProtocol.serve(stream);
    });

    handle(IdentifyProtocol.protocolId, (connection, stream) {
      return IdentifyProtocol.writeMessage(
        stream,
        IdentifySnapshot(
          protocolVersion: protocolVersion,
          agentVersion: agentVersion,
          publicKey: PeerId.marshalPublicKey(
            KeyType.ed25519,
            identity.publicKeyBytes,
          ),
          listenAddrs: listenAddrs,
          observedAddr: connection.remoteAddress,
          protocols: supportedProtocols.toList()..sort(),
        ),
      );
    });
    await protocolRegistry.registerService(this, kadDht);
    await protocolRegistry.registerService(this, relay);
    await protocolRegistry.registerService(this, dcutr);
  }

  Future<HostConnection> _upgradeOutgoing(
    RawConnection rawConnection,
    Multiaddr dialedAddress,
  ) async {
    final noise = NoiseProtocol(identity);
    final security = await noise.secureOutbound(rawConnection);
    final negotiationStream = await _upgradeToMplexInitiator(security.connection);
    return HostConnection(
      host: this,
      remotePeerId: security.remotePeerId,
      remoteAddress: dialedAddress,
      multiplexer: negotiationStream,
    );
  }

  Future<HostConnection> _upgradeIncoming(RawConnection rawConnection) async {
    final noise = NoiseProtocol(identity);
    final security = await noise.secureInbound(rawConnection);
    final multiplexer = await _upgradeToMplexListener(security.connection);
    return HostConnection(
      host: this,
      remotePeerId: security.remotePeerId,
      remoteAddress: rawConnection.remoteAddress,
      multiplexer: multiplexer,
    );
  }

  Future<MplexConnection> _upgradeToMplexInitiator(ConnectionIO connection) async {
    final stream = Libp2pStream(connection);
    await MultistreamSelect.negotiateInitiator(stream, '/mplex/6.7.0');
    return MplexConnection(connection);
  }

  Future<MplexConnection> _upgradeToMplexListener(ConnectionIO connection) async {
    final stream = Libp2pStream(connection);
    final negotiated = await MultistreamSelect.negotiateListener(stream, {
      '/mplex/6.7.0',
    });
    if (negotiated != '/mplex/6.7.0') {
      throw StateError('unexpected muxer protocol: $negotiated');
    }
    return MplexConnection(connection);
  }

  void _serveIncomingStreams(HostConnection connection) {
    connection._multiplexer.incomingStreams.listen((stream) async {
      _serveNegotiatedStream(connection.remotePeerId, stream);
    });
  }

  void _serveNegotiatedStream(PeerId remotePeerId, Libp2pStream stream) async {
    try {
      final protocol = await MultistreamSelect.negotiateListener(
        stream,
        supportedProtocols,
      );
      final handler = protocolRegistry.handlerFor(protocol);
      if (handler != null) {
        // We need a HostConnection for the handler.
        // For relayed streams, we might not have a direct HostConnection.
        // For now, let's try to find an existing one or just use the stream.
        final connection = connectionManager.connectionFor(remotePeerId);
        if (connection != null) {
          await handler(connection, stream);
        } else {
          // If no direct connection, try to find a relayed connection or create a pseudo-connection
          // For now, let's just create a temporary HostConnection if we have enough info
          // (Actually, PeerStore should have the address)
          final record = peerStore.getPeer(remotePeerId);
          if (record != null && record.addrs.isNotEmpty) {
            // This is still tricky without a real multiplexer.
            // For now, skip and just close.
            await stream.close();
          } else {
            await stream.close();
          }
        }
      } else {
        await stream.close();
      }
    } catch (_) {
      await stream.close();
    }
  }
}
