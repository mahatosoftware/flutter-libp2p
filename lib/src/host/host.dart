import 'dart:async';
import 'dart:typed_data';

import '../address/multiaddr.dart';
import '../core/connection_io.dart';
import '../core/libp2p_stream.dart';
import '../core/discovery.dart';
import '../core/mdns_discovery.dart';
import '../core/muxer.dart';
import '../core/transport.dart';
import '../identity/keypair.dart';
import '../identity/peer_id.dart';
import '../protocols/kad_dht.dart';
import '../protocols/identify.dart';
import '../protocols/mplex.dart';
import '../protocols/yamux.dart';
import '../protocols/tls.dart';
import '../protocols/noise.dart';
import '../protocols/ping.dart';
import '../protocols/relay_v2.dart';
import '../protocols/dcutr.dart';
import '../protocols/gossipsub.dart';
import '../protocols/autonat.dart';
import '../protocols/multistream_select.dart';
import 'connection_manager.dart';
import 'peer_store.dart';
import 'protocol_registry.dart';
import 'tcp_transport.dart';
import 'quic_transport.dart';
import 'webrtc_transport.dart';
import 'webtransport_transport.dart';
import 'udx_transport.dart';

class HostConnection {
  HostConnection({
    required this.host,
    required this.remotePeerId,
    required this.remoteAddress,
    required StreamMuxer multiplexer, // Changed MplexConnection to StreamMuxer
  })  : _multiplexer = multiplexer,
        createdAt = DateTime.now(),
        lastActiveAt = DateTime.now();

  final Libp2pHost host;
  final PeerId remotePeerId;
  final Multiaddr remoteAddress;
  final DateTime createdAt;
  DateTime lastActiveAt;
  final StreamMuxer _multiplexer; // Changed MplexConnection to StreamMuxer

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
    required this.transports,
    required this.protocolVersion,
    required this.agentVersion,
    required this.peerStore,
    required this.connectionManager,
    required this.protocolRegistry,
    required this.kadDht,
    required this.relay,
    required this.dcutr,
    required this.gossipsub,
    required this.autonat,
  });

  final Libp2pKeyPair identity;
  final PeerId peerId;
  final List<Transport> transports;
  final String protocolVersion;
  final String agentVersion;
  final PeerStore peerStore;
  final ConnectionManager connectionManager;
  final ProtocolRegistry protocolRegistry;
  final KadDhtService kadDht;
  final RelayService relay;
  final DcutrProtocol dcutr;
  final GossipsubService gossipsub;
  final AutoNATService autonat;
  final List<DiscoveryService> discoveryServices = <DiscoveryService>[];
  final List<Multiaddr> _listenAddrs = <Multiaddr>[];
  final List<ConnectionListener> _listeners = <ConnectionListener>[];

  static Future<Libp2pHost> create({
    Libp2pKeyPair? identity,
    List<Transport>? transports,
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
    final gossipsub = GossipsubService();
    final autonat = AutoNATService();

    final host = Libp2pHost._(
      identity: localIdentity,
      peerId: peerId,
      transports: transports ?? [
        TcpTransport(),
        UdxTransport(),
        QuicTransport(),
        WebRTCTransport(localIdentity),
        WebTransportTransport(),
      ],
      protocolVersion: protocolVersion,
      agentVersion: agentVersion,
      peerStore: actualPeerStore,
      connectionManager: actualConnectionManager,
      protocolRegistry: protocolRegistry,
      kadDht: kadDht,
      relay: relay,
      dcutr: dcutr,
      gossipsub: gossipsub,
      autonat: autonat,
    );
    await host._registerBuiltins();
    
    // Default mDNS discovery
    final mdns = MdnsDiscovery(peerId: peerId);
    host.discoveryServices.add(mdns);
    mdns.events.listen((event) {
        print('Discovered peer: ${event.peerId} at ${event.addrs}');
        for (final addr in event.addrs) {
            host.kadDht.addPeer(event.peerId, addr: addr);
        }
    });

    return host;
  }

  List<Multiaddr> get listenAddrs => List<Multiaddr>.unmodifiable(_listenAddrs);

  Set<String> get supportedProtocols => protocolRegistry.supportedProtocols;

  void handle(String protocolId, StreamHandler handler) {
    protocolRegistry.registerHandler(protocolId, handler);
  }

  Future<HostConnection> connectToPeer(PeerId peerId) async {
    final record = peerStore.getPeer(peerId);
    if (record == null || record.addrs.isEmpty) {
      // 1. Try to find peer in DHT
      final found = await kadDht.findPeer(peerId);
      if (found == null || found.addrs.isEmpty) {
        throw StateError('could not find address for peer: ${peerId.toBase58()}');
      }
      return connect(found.addrs.first);
    }
    return connect(record.addrs.first);
  }

  Future<Multiaddr> listen(Multiaddr address) async {
    Transport? transport;
    for (final t in transports) {
      if (t.canDial(address)) {
        transport = t;
        break;
      }
    }
    if (transport == null) {
      throw StateError('No transport found for address: $address');
    }

    final listener = await transport.listen(address);
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
    if (address.toString().contains('p2p-circuit')) {
        // Example: /p2p/RELAY_ID/p2p-circuit/p2p/DEST_ID OR /ip4/RELAY_IP/.../p2p/RELAY_ID/p2p-circuit/p2p/DEST_ID
        final components = address.components;
        final circuitIdx = components.indexWhere((c) => c.protocol == 'p2p-circuit');
        
        // Everything before p2p-circuit is the target relay
        final relayAddr = Multiaddr(components.sublist(0, circuitIdx));
        final relayConn = await connect(relayAddr);
        
        // Everything after p2p-circuit is the target peer (usually just /p2p/DEST_ID)
        final destPeerIdStr = components.lastWhere((c) => c.protocol == 'p2p').value!;
        final destPeerId = PeerId.fromBase58(destPeerIdStr);
        
        final relayStream = await relay.connect(relayConn, destPeerId);
        final connection = await _upgradeOutgoing(_RelayedConnectionIO(relayStream), address);
        await connectionManager.register(connection);
        peerStore.markConnected(connection.remotePeerId, connection.remoteAddress);
        kadDht.addPeer(connection.remotePeerId, addr: connection.remoteAddress);
        _serveIncomingStreams(connection);
        return connection;
    }

    final rawAddress = Multiaddr(
      address.components
          .where((component) => component.protocol != 'p2p')
          .toList(),
    );
    
    Transport? transport;
    for (final t in transports) {
      if (t.canDial(rawAddress)) {
        transport = t;
        break;
      }
    }
    if (transport == null) {
      throw StateError('No transport found for address: $rawAddress');
    }

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
    for (final discovery in discoveryServices) {
       await discovery.stop();
    }
    for (final listener in _listeners) {
      await listener.close();
    }
    await connectionManager.closeAll();
  }

  void handleRelayedStream(PeerId remotePeerId, Libp2pStream stream) {
    unawaited(_handleRelayedStreamAsync(stream));
  }

  Future<void> _handleRelayedStreamAsync(Libp2pStream stream) async {
    try {
      final connection = await _upgradeIncoming(_RelayedConnectionIO(stream), Multiaddr.parse('/p2p-circuit'));
      await connectionManager.register(connection);
      peerStore.markConnected(connection.remotePeerId, connection.remoteAddress);
      kadDht.addPeer(connection.remotePeerId, addr: connection.remoteAddress);
      _serveIncomingStreams(connection);
    } catch (_) {
      await stream.close();
    }
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
    await protocolRegistry.registerService(this, gossipsub);
    await protocolRegistry.registerService(this, autonat);
  }

  Future<HostConnection> _upgradeOutgoing(
    ConnectionIO io,
    Multiaddr dialedAddress,
  ) async {
    if (io is StreamMuxer) {
        // Authenticated and muxed already (e.g. QUIC)
        // But we need a PeerId. For QUIC we should already have one.
        // For now let's assume security is tied to the IO.
        // We'll need to extract remotePeerId from the connection.
        final peerIdStr = dialedAddress.valueForProtocol('p2p');
        return HostConnection(
            host: this,
            remotePeerId: peerIdStr != null ? PeerId.fromBase58(peerIdStr) : PeerId.fromBase58('dummy'), // Should get real id
            remoteAddress: dialedAddress,
            multiplexer: io as StreamMuxer,
        );
    }
    
    final noise = NoiseProtocol(identity);
    final tls = TlsProtocol(identity);
    // Security negotiation: Try TLS first, then fall back to Noise
    // Actually, libp2p usually uses multistream-select to decide
    // For now, continue with Noise but add a check if io already secured
    
    final security = await noise.secureOutbound(io);
    final negotiationStream = await _upgradeToMuxerInitiator(security.connection);
    return HostConnection(
      host: this,
      remotePeerId: security.remotePeerId,
      remoteAddress: dialedAddress,
      multiplexer: negotiationStream,
    );
  }
 
  Future<HostConnection> _upgradeIncoming(
    ConnectionIO io,
    [Multiaddr? addr]
  ) async {
    if (io is StreamMuxer) {
        // Naturally secured/muxed connection
        // We need the remote peer id somehow.
        return HostConnection(
            host: this,
            remotePeerId: PeerId.fromBase58('dummy'), // Needs real peer id from handshake
            remoteAddress: addr ?? Multiaddr.parse('/p2p-circuit'),
            multiplexer: io as StreamMuxer,
        );
    }
 
    final noise = NoiseProtocol(identity);
    final security = await noise.secureInbound(io);
    final multiplexer = await _upgradeToMuxerListener(security.connection);
    return HostConnection(
      host: this,
      remotePeerId: security.remotePeerId,
      remoteAddress: addr ?? (io is RawConnection ? (io as RawConnection).remoteAddress : Multiaddr.parse('/p2p-circuit')),
      multiplexer: multiplexer,
    );
  }
 
  Future<StreamMuxer> _upgradeToMuxerInitiator(ConnectionIO connection) async {
    final stream = Libp2pStream(connection);
    final negotiated = await MultistreamSelect.negotiateInitiatorMulti(stream, [
       '/yamux/1.0.0',
       '/mplex/6.7.0',
    ]);
    
    if (negotiated == '/yamux/1.0.0') {
       return YamuxConnection(connection);
    }
    return MplexConnection(connection);
  }
 
  Future<StreamMuxer> _upgradeToMuxerListener(ConnectionIO connection) async {
    final stream = Libp2pStream(connection);
    final negotiated = await MultistreamSelect.negotiateListener(stream, {
      '/yamux/1.0.0',
      '/mplex/6.7.0',
    });
    if (negotiated == '/yamux/1.0.0') {
      return YamuxConnection(connection);
    } else if (negotiated == '/mplex/6.7.0') {
      return MplexConnection(connection);
    }
    throw StateError('unexpected muxer protocol: $negotiated');
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

class _RelayedConnectionIO implements ConnectionIO {
  _RelayedConnectionIO(this._stream) : reader = ByteReader(_stream.inputStream);

  final Libp2pStream _stream;
  @override
  final ByteReader reader;
  @override
  Stream<Uint8List> get input => _stream.inputStream;

  @override
  void send(Uint8List bytes) => _stream.write(bytes);

  @override
  Future<void> close() => _stream.close();
}
