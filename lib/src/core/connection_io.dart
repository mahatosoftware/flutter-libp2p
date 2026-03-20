import 'dart:async';
import 'dart:typed_data';

import '../crypto/varint.dart';

abstract interface class ConnectionIO {
  ByteReader get reader;
  Stream<Uint8List> get input;

  void send(Uint8List bytes);

  Future<void> close();
}

class ByteReader {
  ByteReader(Stream<Uint8List> source, {this.onBytesConsumed}) {
    _subscription = source.listen(
      _onData,
      onDone: _onDone,
      onError: _onError,
      cancelOnError: false,
    );
  }

  final List<int> _buffer = <int>[];
  final List<_PendingRead> _pending = <_PendingRead>[];
  late final StreamSubscription<Uint8List> _subscription;
  final void Function(int bytes)? onBytesConsumed;
  Object? _error;
  bool _isDone = false;

  Future<Uint8List> readExact(int length) {
    if (length < 0) {
      throw ArgumentError.value(length, 'length', 'must be non-negative');
    }
    if (_error != null) {
      return Future<Uint8List>.error(_error!);
    }
    if (_buffer.length >= length) {
      return Future<Uint8List>.value(_take(length));
    }
    if (_isDone) {
      return Future<Uint8List>.error(
        StateError('stream ended before $length bytes were available'),
      );
    }

    final completer = Completer<Uint8List>();
    _pending.add(_PendingRead(length, completer));
    return completer.future;
  }

  Future<int> readUVarint() async {
    var shift = 0;
    var value = 0;
    while (true) {
      final byte = (await readExact(1))[0];
      value |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) {
        return value;
      }
      shift += 7;
      if (shift > 63) {
        throw const FormatException('varint is too long');
      }
    }
  }

  Future<Uint8List> readLengthPrefixed() async {
    final length = await readUVarint();
    return readExact(length);
  }

  void _onData(Uint8List data) {
    _buffer.addAll(data);
    _drainPending();
  }

  void _onDone() {
    _isDone = true;
    _drainPending();
  }

  void _onError(Object error, StackTrace stackTrace) {
    _error = error;
    while (_pending.isNotEmpty) {
      _pending.removeAt(0).completer.completeError(error, stackTrace);
    }
  }

  void _drainPending() {
    while (_pending.isNotEmpty) {
      final pending = _pending.first;
      if (_buffer.length >= pending.length) {
        _pending.removeAt(0).completer.complete(_take(pending.length));
        continue;
      }
      if (_isDone) {
        _pending
            .removeAt(0)
            .completer
            .completeError(
              StateError(
                'stream ended before ${pending.length} bytes were available',
              ),
            );
        continue;
      }
      break;
    }
  }

  Uint8List _take(int length) {
    final bytes = Uint8List.fromList(_buffer.sublist(0, length));
    _buffer.removeRange(0, length);
    onBytesConsumed?.call(length);
    return bytes;
  }

  Future<void> cancel() => _subscription.cancel();
}

class FramedConnection {
  FramedConnection(this.io) : reader = io.reader;

  final ConnectionIO io;
  final ByteReader reader;

  Future<Uint8List> readLengthPrefixed() => reader.readLengthPrefixed();

  void writeLengthPrefixed(List<int> bytes) {
    io.send(Uint8List.fromList([...encodeUVarint(bytes.length), ...bytes]));
  }

  Future<void> close() => io.close();
}

class _PendingRead {
  _PendingRead(this.length, this.completer);

  final int length;
  final Completer<Uint8List> completer;
}
