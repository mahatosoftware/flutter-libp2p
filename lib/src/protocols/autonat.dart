import 'dart:async';
import 'dart:typed_data';

import '../host/host.dart';
import '../identity/peer_id.dart';
import '../core/libp2p_stream.dart';
import '../host/protocol_registry.dart';
import '../crypto/protobuf.dart';
import '../address/multiaddr.dart';

enum AutoNATResponseStatus {
  ok(0),
  eDialError(1),
  eDialRefused(2),
  eInternalError(3);

  const AutoNATResponseStatus(this.code);
  final int code;
}

class AutoNATService implements HostService {
  static const protocolId = '/libp2p/autonat/1.0.0';

  Libp2pHost? _host;

  @override
  Iterable<ProtocolRegistration> get protocolRegistrations => <ProtocolRegistration>[
        ProtocolRegistration(protocolId, _handleStream),
      ];

  @override
  Future<void> start(Libp2pHost host) async {
    _host = host;
    _checkReachability();
  }

  @override
  Future<void> stop() async {
    _host = null;
  }

  Future<void> _checkReachability() async {
     // Periodically ask peers to dial back to check if we are publicly reachable
  }

  Future<void> _handleStream(HostConnection connection, Libp2pStream stream) async {
     // Handle incoming dial-back requests
     final bytes = await stream.readLengthPrefixed();
     // ... Decode request and attempt dial ...
     await stream.writeLengthPrefixed(Uint8List.fromList([
         ...protoEnum(2, AutoNATResponseStatus.ok.code),
     ]));
     await stream.close();
  }
}
