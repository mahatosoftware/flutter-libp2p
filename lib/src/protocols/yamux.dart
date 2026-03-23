import 'dart:async';
import 'dart:typed_data';

import '../core/connection_io.dart';
import '../core/libp2p_stream.dart';
import '../core/muxer.dart';

enum YamuxType {
  data(0),
  windowUpdate(1),
  ping(2),
  goAway(3);

  const YamuxType(this.code);
  final int code;
}

class YamuxFlags {
  static const syn = 1 << 0;
  static const ack = 1 << 1;
  static const fin = 1 << 2;
  static const rst = 1 << 3;
}

class YamuxFrame {
  YamuxFrame({
    required this.version,
    required this.type,
    required this.flags,
    required this.streamId,
    required this.length,
    this.data = const [],
  });

  final int version;
  final YamuxType type;
  final int flags;
  final int streamId;
  final int length;
  final List<int> data;

  Uint8List encode() {
    final buffer = Uint8List(12 + data.length);
    final view = ByteData.sublistView(buffer);
    view.setUint8(0, version);
    view.setUint8(1, type.code);
    view.setUint16(2, flags);
    view.setUint32(4, streamId);
    view.setUint32(8, length);
    buffer.setRange(12, 12 + data.length, data);
    return buffer;
  }

  static Future<YamuxFrame> decode(ByteReader reader) async {
    final header = await reader.readExact(12);
    final view = ByteData.sublistView(header);
    final version = view.getUint8(0);
    final typeCode = view.getUint8(1);
    final flags = view.getUint16(2);
    final streamId = view.getUint32(4);
    final length = view.getUint32(8);

    final type = YamuxType.values.firstWhere((t) => t.code == typeCode);
    Uint8List data = Uint8List(0);
    if (type == YamuxType.data && length > 0) {
      data = await reader.readExact(length);
    }

    return YamuxFrame(
      version: version,
      type: type,
      flags: flags,
      streamId: streamId,
      length: length,
      data: data,
    );
  }
}

class YamuxStream extends Libp2pStream {
  YamuxStream._({
    required this.id,
    required _YamuxStreamIO io,
  }) : _io = io,
       super(io);

  final int id;
  final _YamuxStreamIO _io;

  @override
  Future<void> close() => _io.close();
}

class YamuxConnection implements StreamMuxer {
  YamuxConnection(this._io)
    : _reader = _io.reader,
      _incomingController = StreamController<YamuxStream>.broadcast() {
    _readLoop();
  }

  final ConnectionIO _io;
  final ByteReader _reader;
  final StreamController<YamuxStream> _incomingController;
  final Map<int, _YamuxStreamIO> _streams = <int, _YamuxStreamIO>{};
  int _nextStreamId = 1; // Clients use odd, servers use even? (Actually libp2p uses 0 for session)
  bool _closed = false;

  @override
  Stream<YamuxStream> get incomingStreams => _incomingController.stream;

  @override
  Future<YamuxStream> openStream([String name = '']) async {
    final id = _nextStreamId;
    _nextStreamId += 2;
    final streamIo = _YamuxStreamIO(this, id);
    _streams[id] = streamIo;
    
    _sendFrame(YamuxFrame(
      version: 0,
      type: YamuxType.data,
      flags: YamuxFlags.syn,
      streamId: id,
      length: 0,
    ));
    
    return YamuxStream._(id: id, io: streamIo);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _sendFrame(YamuxFrame(
      version: 0,
      type: YamuxType.goAway,
      flags: 0,
      streamId: 0,
      length: 0,
    ));
    for (final stream in _streams.values) {
      stream.markClosed();
    }
    _streams.clear();
    await _incomingController.close();
    await _io.close();
  }

  void _sendFrame(YamuxFrame frame) {
    if (_closed) return;
    _io.send(frame.encode());
  }

  Future<void> _readLoop() async {
    try {
      while (!_closed) {
        final frame = await YamuxFrame.decode(_reader);
        await _handleFrame(frame);
      }
    } catch (_) {
      await close();
    }
  }

  Future<void> _handleFrame(YamuxFrame frame) async {
    switch (frame.type) {
      case YamuxType.data:
        var stream = _streams[frame.streamId];
        if (stream == null) {
          if (frame.flags & YamuxFlags.syn != 0) {
             stream = _YamuxStreamIO(this, frame.streamId);
             _streams[frame.streamId] = stream;
             _incomingController.add(YamuxStream._(id: frame.streamId, io: stream));
             if (frame.flags & YamuxFlags.ack == 0) {
                // Send back ACK
                _sendFrame(YamuxFrame(
                    version: 0,
                    type: YamuxType.windowUpdate,
                    flags: YamuxFlags.ack,
                    streamId: frame.streamId,
                    length: 0,
                ));
             }
          } else {
             // Protocol error?
             return;
          }
        }
        if (frame.data.isNotEmpty) {
           stream.addIncoming(Uint8List.fromList(frame.data));
        }
        if (frame.flags & YamuxFlags.fin != 0) {
           _streams.remove(frame.streamId)?.markClosed();
        }
        if (frame.flags & YamuxFlags.rst != 0) {
           _streams.remove(frame.streamId)?.markClosed();
        }
        break;
      case YamuxType.windowUpdate:
        // Handle window update for flow control
        break;
      case YamuxType.ping:
        if (frame.flags & YamuxFlags.syn != 0) {
           // Respond to ping
           _sendFrame(YamuxFrame(
               version: 0,
               type: YamuxType.ping,
               flags: YamuxFlags.ack,
               streamId: frame.streamId,
               length: frame.length,
           ));
        }
        break;
      case YamuxType.goAway:
        await close();
        break;
    }
  }
}

class _YamuxStreamIO implements ConnectionIO {
  _YamuxStreamIO(this._parent, this.streamId);

  final YamuxConnection _parent;
  final int streamId;
  final StreamController<Uint8List> _incomingController = StreamController<Uint8List>.broadcast();
  bool _closed = false;

  @override
  Stream<Uint8List> get input => _incomingController.stream;

  @override
  late final ByteReader reader = ByteReader(input);

  void addIncoming(Uint8List bytes) {
    if (_closed) return;
    _incomingController.add(bytes);
  }

  @override
  void send(Uint8List bytes) {
    if (_closed) throw StateError('stream is closed');
    _parent._sendFrame(YamuxFrame(
      version: 0,
      type: YamuxType.data,
      flags: 0,
      streamId: streamId,
      length: bytes.length,
      data: bytes,
    ));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _parent._sendFrame(YamuxFrame(
      version: 0,
      type: YamuxType.data,
      flags: YamuxFlags.fin,
      streamId: streamId,
      length: 0,
    ));
    _parent._streams.remove(streamId);
    await _incomingController.close();
  }

  void markClosed() {
    if (_closed) return;
    _closed = true;
    _incomingController.close();
  }
}
