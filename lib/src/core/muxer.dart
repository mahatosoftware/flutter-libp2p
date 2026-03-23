import 'libp2p_stream.dart';

abstract interface class StreamMuxer {
  Stream<Libp2pStream> get incomingStreams;
  Future<Libp2pStream> openStream([String name = 'stream']);
  Future<void> close();
}
