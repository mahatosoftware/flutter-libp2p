import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/connection_io.dart';
import '../core/libp2p_stream.dart';
import '../identity/keypair.dart';
import '../identity/peer_id.dart';
import 'multistream_select.dart';

class TlsHandshakeResult {
  TlsHandshakeResult({
    required this.connection,
    required this.remotePeerId,
  });

  final ConnectionIO connection;
  final PeerId remotePeerId;
}

class TlsProtocol {
  static const protocolId = '/tls/1.3.0';

  TlsProtocol(this.localKeyPair);
  final Libp2pKeyPair localKeyPair;

  Future<TlsHandshakeResult> secureOutbound(ConnectionIO io, {String? host}) async {
    final stream = Libp2pStream(io);
    await MultistreamSelect.negotiateInitiator(stream, protocolId);
    
    // In libp2p, we use RawSecureSocket or similar if available.
    // However, direct SecureSocket.connect requires a real socket.
    // For libp2p-TLS, we usually need to wrap the existing ConnectionIO.
    // This is hard with dart:io SecureSocket as it doesn't take a custom Stream/Sink.
    
    // For now, this is a placeholder that would be backed by a TLS 1.3 library that can wrap streams.
    // e.g. using package:tls or similar if available.
    
    return TlsHandshakeResult(
      connection: io, // Should be wrapped in a TLS session
      remotePeerId: PeerId.fromBase58('dummy'), 
    );
  }

  Future<TlsHandshakeResult> secureInbound(ConnectionIO io) async {
    final stream = Libp2pStream(io);
    final negotiated = await MultistreamSelect.negotiateListener(stream, {protocolId});
    if (negotiated != protocolId) {
       throw StateError('unexpected security protocol: $negotiated');
    }
    
    return TlsHandshakeResult(
       connection: io, // Should be wrapped in a TLS session
       remotePeerId: PeerId.fromBase58('dummy'),
    );
  }
}

class _TlsConnection implements ConnectionIO {
  _TlsConnection(this._inner, this._secureSocket);

  final ConnectionIO _inner;
  final SecureSocket _secureSocket;

  @override
  Stream<Uint8List> get input => _secureSocket.asBroadcastStream().map(Uint8List.fromList);

  @override
  late final ByteReader reader = ByteReader(input);

  @override
  void send(Uint8List bytes) => _secureSocket.add(bytes);

  @override
  Future<void> close() async {
    await _secureSocket.close();
    await _inner.close();
  }
}
