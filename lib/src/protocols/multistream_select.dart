import 'dart:convert';

import '../core/libp2p_stream.dart';

class MultistreamSelect {
  static const handshake = '/multistream/1.0.0\n';
  static const Duration negotiationTimeout = Duration(seconds: 10);

  static Future<void> negotiateInitiator(
    Libp2pStream stream,
    String protocol,
  ) async {
    await negotiateInitiatorMulti(stream, [protocol]);
  }

  static Future<String> negotiateInitiatorMulti(
    Libp2pStream stream,
    List<String> protocols,
  ) async {
    stream.writeLengthPrefixedString(handshake);
    final remoteHandshake = await stream
        .readLengthPrefixedString()
        .timeout(negotiationTimeout);
    if (remoteHandshake != handshake) {
      throw StateError('unexpected multistream handshake: $remoteHandshake');
    }

    for (final protocol in protocols) {
      final p = protocol.endsWith('\n') ? protocol : '$protocol\n';
      stream.writeLengthPrefixedString(p);
      final response = await stream
          .readLengthPrefixedString()
          .timeout(negotiationTimeout);
      if (response == p) {
        return protocol;
      }
      if (response != 'na\n') {
        throw StateError('remote rejected protocol $protocol with: $response');
      }
    }
    throw StateError('remote rejected all protocols: $protocols');
  }

  static Future<String> negotiateListener(
    Libp2pStream stream,
    Set<String> supportedProtocols,
  ) async {
    final remoteHandshake = await stream
        .readLengthPrefixedString()
        .timeout(negotiationTimeout);
    if (remoteHandshake != handshake) {
      throw StateError('unexpected multistream handshake: $remoteHandshake');
    }
    stream.writeLengthPrefixedString(handshake);

    final requestedProtocol = (await stream
            .readLengthPrefixedString()
            .timeout(negotiationTimeout))
        .trim();
    if (!supportedProtocols.contains(requestedProtocol)) {
      stream.writeLengthPrefixed(utf8.encode('na\n'));
      throw StateError('unsupported protocol: $requestedProtocol');
    }
    stream.writeLengthPrefixed(utf8.encode('$requestedProtocol\n'));
    return requestedProtocol;
  }
}
