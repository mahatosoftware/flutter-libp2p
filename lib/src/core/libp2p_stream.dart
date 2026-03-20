import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'connection_io.dart';
import '../crypto/varint.dart';

class Libp2pStream {
  Libp2pStream(this.io) : reader = io.reader;

  final ConnectionIO io;
  final ByteReader reader;

  Stream<Uint8List> get inputStream => io.input;

  Future<Uint8List> read(int length) => reader.readExact(length);

  Future<Uint8List> readLengthPrefixed() => reader.readLengthPrefixed();

  Future<String> readLengthPrefixedString() async {
    final bytes = await readLengthPrefixed();
    return utf8.decode(bytes);
  }

  void write(List<int> bytes) => io.send(Uint8List.fromList(bytes));

  Future<void> writeLengthPrefixed(List<int> bytes) async {
    write([...encodeUVarint(bytes.length), ...bytes]);
  }

  void writeLengthPrefixedString(String value) {
    writeLengthPrefixed(utf8.encode(value));
  }

  Future<void> close() => io.close();
}
