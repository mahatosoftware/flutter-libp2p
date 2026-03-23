import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../core/connection_io.dart';
import '../core/libp2p_stream.dart';
import '../crypto/varint.dart';
import '../core/muxer.dart';

enum _MplexFlag {
  newStream(0),
  messageReceiver(1),
  messageInitiator(2),
  closeReceiver(3),
  closeInitiator(4),
  resetReceiver(5),
  resetInitiator(6);

  const _MplexFlag(this.code);

  final int code;
}

final _flagsByCode = <int, _MplexFlag>{
  for (final flag in _MplexFlag.values) flag.code: flag,
};

class MplexLimits {
  const MplexLimits({
    this.maxOpenStreams = 256,
    this.maxFrameSize = 64 * 1024 - 16,
    this.maxBufferedIncomingBytesPerStream = 256 * 1024,
  });

  final int maxOpenStreams;
  final int maxFrameSize;
  final int maxBufferedIncomingBytesPerStream;
}

class MplexStream extends Libp2pStream {
  MplexStream._({
    required this.id,
    required this.name,
    required this.initiator,
    required _MplexStreamIO io,
  }) : _io = io,
       super(io);

  final int id;
  final String name;
  final bool initiator;
  final _MplexStreamIO _io;

  @override
  Future<void> close() => _io.close();
}


class MplexConnection implements StreamMuxer {
  MplexConnection(this._io, {MplexLimits limits = const MplexLimits()})
    : _reader = _io.reader,
      _incomingController = StreamController<MplexStream>.broadcast(),
      _limits = limits {
    _readLoop();
  }

  final ConnectionIO _io;
  final ByteReader _reader;
  final StreamController<MplexStream> _incomingController;
  final MplexLimits _limits;
  final Map<int, _MplexStreamIO> _streams = <int, _MplexStreamIO>{};
  int _nextStreamId = 0;
  bool _closed = false;

  @override
  Stream<MplexStream> get incomingStreams => _incomingController.stream;

  @override
  Future<MplexStream> openStream([String name = 'stream']) async {
    _ensureOpen();
    if (_streams.length >= _limits.maxOpenStreams) {
      throw StateError('mplex stream limit exceeded');
    }
    final id = _nextStreamId++;
    final streamIo = _MplexStreamIO(
      parent: this,
      streamId: id,
      initiator: true,
      maxBufferedIncomingBytes: _limits.maxBufferedIncomingBytesPerStream,
    );
    _streams[id] = streamIo;
    _sendFrame(id, _MplexFlag.newStream, utf8.encode(name));
    return MplexStream._(id: id, name: name, initiator: true, io: streamIo);
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    for (final stream in _streams.values) {
      stream.markClosed();
    }
    _streams.clear();
    await _incomingController.close();
    await _io.close();
  }

  void sendMessage(int streamId, bool initiator, Uint8List payload) {
    _ensureOpen();
    _sendFrame(
      streamId,
      initiator ? _MplexFlag.messageInitiator : _MplexFlag.messageReceiver,
      payload,
    );
  }

  Future<void> closeStream(int streamId, bool initiator) async {
    _sendFrame(
      streamId,
      initiator ? _MplexFlag.closeInitiator : _MplexFlag.closeReceiver,
      const [],
    );
    _streams.remove(streamId)?.markClosed();
  }

  void _sendFrame(int streamId, _MplexFlag flag, List<int> payload) {
    if (payload.length > _limits.maxFrameSize) {
      throw StateError(
        'mplex frame exceeds max size of ${_limits.maxFrameSize} bytes',
      );
    }
    final header = encodeUVarint((streamId << 3) | flag.code);
    final length = encodeUVarint(payload.length);
    _io.send(Uint8List.fromList([...header, ...length, ...payload]));
  }

  Future<void> _readLoop() async {
    try {
      while (true) {
        final header = await _reader.readUVarint();
        final streamId = header >> 3;
        final flag = header & 0x07;
        final payloadLength = await _reader.readUVarint();
        if (payloadLength > _limits.maxFrameSize) {
          throw StateError(
            'received mplex frame larger than ${_limits.maxFrameSize} bytes',
          );
        }
        final payload = await _reader.readExact(payloadLength);
        await _handleFrame(streamId, flag, payload);
      }
    } catch (_) {
      for (final stream in _streams.values) {
        stream.markClosed();
      }
      _streams.clear();
      await _incomingController.close();
    }
  }

  Future<void> _handleFrame(int streamId, int flag, Uint8List payload) async {
    final frameFlag = _flagsByCode[flag];
    switch (frameFlag) {
      case _MplexFlag.newStream:
        if (_streams.length >= _limits.maxOpenStreams ||
            _streams.containsKey(streamId)) {
          await resetStream(streamId, initiator: false);
          return;
        }
        final streamIo = _MplexStreamIO(
          parent: this,
          streamId: streamId,
          initiator: false,
          maxBufferedIncomingBytes: _limits.maxBufferedIncomingBytesPerStream,
        );
        _streams[streamId] = streamIo;
        _incomingController.add(
          MplexStream._(
            id: streamId,
            name: utf8.decode(payload),
            initiator: false,
            io: streamIo,
          ),
        );
        break;
      case _MplexFlag.messageReceiver:
      case _MplexFlag.messageInitiator:
        final stream = _streams[streamId];
        if (stream == null) {
          await resetStream(streamId, initiator: frameFlag == _MplexFlag.messageReceiver);
          return;
        }
        stream.addIncoming(payload);
        break;
      case _MplexFlag.closeReceiver:
      case _MplexFlag.closeInitiator:
      case _MplexFlag.resetReceiver:
      case _MplexFlag.resetInitiator:
        _streams.remove(streamId)?.markClosed();
        break;
      case null:
        throw StateError('unknown mplex flag: $flag');
    }
  }

  Future<void> resetStream(int streamId, {required bool initiator}) async {
    if (_closed) {
      return;
    }
    _sendFrame(
      streamId,
      initiator ? _MplexFlag.resetInitiator : _MplexFlag.resetReceiver,
      const [],
    );
    _streams.remove(streamId)?.markClosed();
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('mplex connection is closed');
    }
  }
}

class _MplexStreamIO implements ConnectionIO {
  _MplexStreamIO({
    required MplexConnection parent,
    required this.streamId,
    required this.initiator,
    required this.maxBufferedIncomingBytes,
  }) : _parent = parent;

  final MplexConnection _parent;
  final int streamId;
  final bool initiator;
  final int maxBufferedIncomingBytes;
  final StreamController<Uint8List> _incomingController =
      StreamController<Uint8List>.broadcast();
  bool _closed = false;
  int _bufferedIncomingBytes = 0;

  @override
  Stream<Uint8List> get input => _incomingController.stream;

  @override
  late final ByteReader reader = ByteReader(
    input,
    onBytesConsumed: (bytes) {
      _bufferedIncomingBytes -= bytes;
      if (_bufferedIncomingBytes < 0) {
        _bufferedIncomingBytes = 0;
      }
    },
  );

  void addIncoming(Uint8List bytes) {
    if (_closed) {
      return;
    }
    _bufferedIncomingBytes += bytes.length;
    if (_bufferedIncomingBytes > maxBufferedIncomingBytes) {
      _bufferedIncomingBytes -= bytes.length;
      unawaited(_parent.resetStream(streamId, initiator: initiator));
      return;
    }
    _incomingController.add(bytes);
  }

  @override
  void send(Uint8List bytes) {
    if (_closed) {
      throw StateError('stream is closed');
    }
    _parent.sendMessage(streamId, initiator, bytes);
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _parent.closeStream(streamId, initiator);
    await _incomingController.close();
  }

  void markClosed() {
    if (_closed) {
      return;
    }
    _closed = true;
    _incomingController.close();
  }
}
