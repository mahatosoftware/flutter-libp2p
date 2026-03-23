import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../address/multiaddr.dart';
import '../identity/peer_id.dart';
import 'discovery.dart';

class MdnsDiscovery implements DiscoveryService {
  MdnsDiscovery({
    required this.peerId,
    this.addrs = const [],
    this.serviceName = '_p2p._udp.local',
    this.multicastAddress = '224.0.0.251',
    this.port = 5353,
    this.interval = const Duration(seconds: 30),
  }) : _eventController = StreamController<DiscoveryEvent>.broadcast();

  final PeerId peerId;
  final List<Multiaddr> addrs;
  final String serviceName;
  final String multicastAddress;
  final int port;
  final Duration interval;
  final StreamController<DiscoveryEvent> _eventController;

  RawDatagramSocket? _socket;
  Timer? _announceTimer;

  @override
  Stream<DiscoveryEvent> get events => _eventController.stream;

  Future<void> start() async {
    final address = InternetAddress.anyIPv4;
    _socket = await RawDatagramSocket.bind(address, port, reuseAddress: true, reusePort: true);
    final multicastAddr = InternetAddress(multicastAddress);
    _socket!.joinMulticast(multicastAddr);

    _socket!.listen((event) {
      if (event == RawSocketEvent.read) {
        final dg = _socket!.receive();
        if (dg != null) {
          _handlePacket(dg.data);
        }
      }
    });

    _announce();
    _announceTimer = Timer.periodic(interval, (_) => _announce());
  }

  void _announce() {
    if (_socket == null) return;
    
    // Create a basic mDNS response packet
    final packet = _buildResponsePacket();
    _socket!.send(packet, InternetAddress(multicastAddress), port);
  }

  Uint8List _buildResponsePacket() {
    final out = BytesBuilder();
    // Header (ID=0, QR=1, AA=1, QDnd=0, AN=1, NS=0, AR=2)
    out.add([0x00, 0x00, 0x84, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02]);

    // Answer: PTR record
    _writeDomainName(out, serviceName);
    out.add([0x00, 0x0c, 0x00, 0x01, 0x00, 0x00, 0x00, 0x78]); // TYPE=PTR, CLASS=IN, TTL=120
    final instanceName = '${peerId.toBase58()}.$serviceName';
    final nameBytes = _encodeDomainName(instanceName);
    out.add([0x00, nameBytes.length]);
    out.add(nameBytes);

    // Additional: SRV
    _writeDomainName(out, instanceName);
    out.add([0x00, 0x21, 0x00, 0x01, 0x00, 0x00, 0x00, 0x78]); // TYPE=SRV, CLASS=IN, TTL=120
    out.add([0x00, 0x00, 0x00, 0x00, 0x00, 0x00]); // Priority, Weight, Port (Dummy)
    _writeDomainName(out, 'local');

    // Additional: TXT
    _writeDomainName(out, instanceName);
    out.add([0x00, 0x10, 0x00, 0x01, 0x00, 0x00, 0x00, 0x78]); // TYPE=TXT, CLASS=IN, TTL=120
    final txtData = 'dnsaddr=${addrs.join(',')}';
    out.add([0x00, txtData.length + 1, txtData.length]);
    out.add(utf8.encode(txtData));

    return out.toBytes();
  }

  void _handlePacket(Uint8List data) {
    // Basic DNS parser to find p2p mentions
    final text = utf8.decode(data, allowMalformed: true);
    if (text.contains('dnsaddr=')) {
        // Find p2p ID and addresses
        final p2pIdx = text.indexOf('p2p='); // Alternatively use the instance name
        // (This is a simplified parser for simulation, real one would parse DNS records)
    }
  }

  void _writeDomainName(BytesBuilder out, String name) {
     out.add(_encodeDomainName(name));
  }

  Uint8List _encodeDomainName(String name) {
    final builder = BytesBuilder();
    for (final segment in name.split('.')) {
      if (segment.isEmpty) continue;
      builder.addByte(segment.length);
      builder.add(utf8.encode(segment));
    }
    builder.addByte(0);
    return builder.toBytes();
  }

  @override
  void announce(String ns, List<Multiaddr> addrs) {
    _announce();
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _socket?.close();
    await _eventController.close();
  }
}
