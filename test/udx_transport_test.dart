import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:flutter_libp2p/flutter_libp2p.dart';
import 'package:flutter_libp2p/src/host/udx_transport.dart';

void main() {
  group('UdxTransport Integration', () {
    late UdxTransport transport;

    setUp(() {
      transport = UdxTransport();
    });

    test('canDial identifies udx multiaddrs', () {
      expect(transport.canDial(Multiaddr.parse('/ip4/127.0.0.1/udx/1234')), isTrue);
      expect(transport.canDial(Multiaddr.parse('/ip4/127.0.0.1/udp/1234')), isTrue);
      expect(transport.canDial(Multiaddr.parse('/ip4/127.0.0.1/tcp/1234')), isFalse);
    });

    test('can listen and dial on localhost', () async {
      final addr = Multiaddr.parse('/ip4/127.0.0.1/udx/0');
      print('Listening on $addr');
      final listener = await transport.listen(addr);
      
      final listenAddr = listener.address;
      print('Actual Listen Addr: $listenAddr');
      expect(listenAddr.valueForProtocol('udx'), isNot('0'));

      print('Dialing $listenAddr');
      final dialFuture = transport.dial(listenAddr);
      final incomingFuture = listener.incoming.first;

      final dialConn = await dialFuture;
      print('Dialed connected');
      
      final testData = utf8.encode('hello udx');
      print('Sending data...');
      dialConn.send(Uint8List.fromList(testData));

      final incomingConn = await incomingFuture;
      print('Incoming connected');

      expect(dialConn, isNotNull);
      expect(incomingConn, isNotNull);

      print('Awaiting response...');
      final receivedData = await incomingConn.input.first.timeout(Duration(seconds: 4));
      print('Received data!');
      expect(utf8.decode(receivedData), equals('hello udx'));

      await dialConn.close();
      await listener.close();
    });
  });
}
