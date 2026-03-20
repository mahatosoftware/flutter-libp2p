import '../core/libp2p_stream.dart';
import 'host.dart';

typedef StreamHandler =
    Future<void> Function(HostConnection connection, Libp2pStream stream);

class ProtocolRegistration {
  const ProtocolRegistration(this.protocolId, this.handler);

  final String protocolId;
  final StreamHandler handler;
}

abstract interface class HostService {
  Iterable<ProtocolRegistration> get protocolRegistrations;

  Future<void> start(Libp2pHost host) async {}

  Future<void> stop() async {}
}

class ProtocolRegistry {
  final Map<String, StreamHandler> _handlers = <String, StreamHandler>{};
  final List<HostService> _services = <HostService>[];

  Set<String> get supportedProtocols => _handlers.keys.toSet();

  StreamHandler? handlerFor(String protocolId) => _handlers[protocolId];

  void registerHandler(String protocolId, StreamHandler handler) {
    _handlers[protocolId] = handler;
  }

  void unregisterHandler(String protocolId) {
    _handlers.remove(protocolId);
  }

  Future<void> registerService(Libp2pHost host, HostService service) async {
    _services.add(service);
    for (final registration in service.protocolRegistrations) {
      registerHandler(registration.protocolId, registration.handler);
    }
    await service.start(host);
  }

  Future<void> stopAllServices() async {
    for (final service in _services.reversed) {
      await service.stop();
    }
    _services.clear();
    _handlers.clear();
  }
}
