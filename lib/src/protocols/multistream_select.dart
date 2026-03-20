import 'dart:convert';

import '../core/libp2p_stream.dart';

class MultistreamSelect {
  static const handshake = '/multistream/1.0.0\n';
  static const Duration negotiationTimeout = Duration(seconds: 10);

  static Future<void> negotiateInitiator(
    Libp2pStream stream,
    String protocol,
  ) async {
    stream.writeLengthPrefixedString(handshake);
    final remoteHandshake = await stream
        .readLengthPrefixedString()
        .timeout(negotiationTimeout);
    if (remoteHandshake != handshake) {
      throw StateError('unexpected multistream handshake: $remoteHandshake');
    }

    stream.writeLengthPrefixed(utf8.encode('$protocol\n'));
    final response = await stream
        .readLengthPrefixedString()
        .timeout(negotiationTimeout);
    if (response != '$protocol\n') {
      throw StateError('remote rejected protocol $protocol with: $response');
    }
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
