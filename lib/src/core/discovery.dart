import '../address/multiaddr.dart';
import '../identity/peer_id.dart';

abstract class DiscoveryService {
  Stream<DiscoveryEvent> get events;
  void announce(String ns, List<Multiaddr> addrs);
  Future<void> stop();
}

class DiscoveryEvent {
  DiscoveryEvent({
    required this.peerId,
    required this.addrs,
    this.namespace,
  });

  final PeerId peerId;
  final List<Multiaddr> addrs;
  final String? namespace;
}
