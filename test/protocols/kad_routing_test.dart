import 'dart:typed_data';

import 'package:flutter_libp2p/src/protocols/kad_routing.dart';
import 'package:test/test.dart';

void main() {
  group('XOR Distance Properies', () {
    test('Reflexivity: d(A, A) == 0', () {
      final a = Uint8List.fromList([1, 2, 3, 4]);
      expect(xorDistance(a, a), equals(BigInt.zero));
    });

    test('Symmetry: d(A, B) == d(B, A)', () {
      final a = Uint8List.fromList([1, 2, 3, 4]);
      final b = Uint8List.fromList([5, 6, 7, 8]);
      expect(xorDistance(a, b), equals(xorDistance(b, a)));
    });

    test('Correct bit manipulation for bytes', () {
      final a = Uint8List.fromList([0x01]);
      final b = Uint8List.fromList([0x02]);
      // 0x01 ^ 0x02 = 0x03
      expect(xorDistance(a, b), equals(BigInt.from(3)));
    });

    test('Triangle inequality-ish (d(A, B) ^ d(B, C) == d(A, C))', () {
      final a = Uint8List.fromList([1, 2, 3, 4]);
      final b = Uint8List.fromList([5, 6, 7, 8]);
      final c = Uint8List.fromList([9, 10, 11, 12]);
      
      final dab = xorDistance(a, b);
      final dbc = xorDistance(b, c);
      final dac = xorDistance(a, c);
      
      expect(dab ^ dbc, equals(dac));
    });
  });
}
