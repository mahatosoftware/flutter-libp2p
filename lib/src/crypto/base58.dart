import 'dart:typed_data';

const _alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
final _alphabetIndexes = <int, int>{
  for (var i = 0; i < _alphabet.length; i++) _alphabet.codeUnitAt(i): i,
};

String encodeBase58(Uint8List data) {
  if (data.isEmpty) {
    return '';
  }

  final digits = <int>[0];
  for (final byte in data) {
    var carry = byte;
    for (var i = 0; i < digits.length; i++) {
      carry += digits[i] << 8;
      digits[i] = carry % 58;
      carry ~/= 58;
    }
    while (carry > 0) {
      digits.add(carry % 58);
      carry ~/= 58;
    }
  }

  final encoded = StringBuffer();
  for (final byte in data) {
    if (byte != 0) {
      break;
    }
    encoded.write('1');
  }

  for (var i = digits.length - 1; i >= 0; i--) {
    encoded.write(_alphabet[digits[i]]);
  }
  return encoded.toString();
}

Uint8List decodeBase58(String value) {
  if (value.isEmpty) {
    return Uint8List(0);
  }

  final bytes = <int>[0];
  for (final rune in value.codeUnits) {
    final index = _alphabetIndexes[rune];
    if (index == null) {
      throw FormatException(
        'Invalid base58 character: ${String.fromCharCode(rune)}',
      );
    }

    var carry = index;
    for (var i = 0; i < bytes.length; i++) {
      carry += bytes[i] * 58;
      bytes[i] = carry & 0xff;
      carry >>= 8;
    }
    while (carry > 0) {
      bytes.add(carry & 0xff);
      carry >>= 8;
    }
  }

  for (final rune in value.codeUnits) {
    if (rune != '1'.codeUnitAt(0)) {
      break;
    }
    bytes.add(0);
  }

  return Uint8List.fromList(bytes.reversed.toList(growable: false));
}
