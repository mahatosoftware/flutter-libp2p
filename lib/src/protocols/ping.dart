import 'dart:math';
import 'dart:typed_data';

import '../core/libp2p_stream.dart';

class PingProtocol {
  static const protocolId = '/ipfs/ping/1.0.0';
  static final Random _random = Random.secure();

  static Future<Duration> ping(Libp2pStream stream) async {
    final payload = Uint8List.fromList(
      List<int>.generate(32, (_) => _random.nextInt(256), growable: false),
    );
    final started = DateTime.now();
    stream.write(payload);
    final echo = await stream.read(32);
    if (!_matches(payload, echo)) {
      throw StateError('remote ping response does not match request payload');
    }
    await stream.close();
    return DateTime.now().difference(started);
  }

  static Future<void> serve(Libp2pStream stream) async {
    final payload = await stream.read(32);
    stream.write(payload);
    await stream.close();
  }

  static bool _matches(Uint8List expected, Uint8List actual) {
    if (expected.length != actual.length) {
      return false;
    }
    for (var i = 0; i < expected.length; i++) {
      if (expected[i] != actual[i]) {
        return false;
      }
    }
    return true;
  }
}
