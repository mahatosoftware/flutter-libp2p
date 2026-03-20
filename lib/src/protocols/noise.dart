import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import '../core/connection_io.dart';
import '../core/libp2p_stream.dart';
import '../crypto/protobuf.dart';
import '../identity/keypair.dart';
import '../identity/peer_id.dart';
import 'multistream_select.dart';

class NoiseHandshakeResult {
  NoiseHandshakeResult({
    required this.connection,
    required this.remotePeerId,
    required this.remotePublicKey,
  });

  final ConnectionIO connection;
  final PeerId remotePeerId;
  final Uint8List remotePublicKey;
}

class NoiseProtocol {
  static const protocolId = '/noise';
  static const Duration handshakeTimeout = Duration(seconds: 10);
  static const int maxTransportMessageSize = 64 * 1024 - 16;
  static const _prefix = 'noise-libp2p-static-key:';
  static final Uint8List _protocolName = Uint8List.fromList(
    utf8.encode('Noise_XX_25519_ChaChaPoly_SHA256'),
  );
  static final Uint8List _prefixBytes = Uint8List.fromList(utf8.encode(_prefix));
  static final DartX25519 _x25519 = DartX25519();
  static final DartChacha20 _cipher = DartChacha20.poly1305Aead();

  NoiseProtocol(this.localKeyPair);

  final Libp2pKeyPair localKeyPair;

  Future<NoiseHandshakeResult> secureOutbound(ConnectionIO io) async {
    final stream = Libp2pStream(io);
    await MultistreamSelect.negotiateInitiator(stream, protocolId);
    return _runHandshake(io, initiator: true);
  }

  Future<NoiseHandshakeResult> secureInbound(ConnectionIO io) async {
    final stream = Libp2pStream(io);
    final negotiated = await MultistreamSelect.negotiateListener(stream, {
      protocolId,
    });
    if (negotiated != protocolId) {
      throw StateError('unexpected security protocol: $negotiated');
    }
    return _runHandshake(io, initiator: false);
  }

  Future<NoiseHandshakeResult> _runHandshake(
    ConnectionIO io, {
    required bool initiator,
  }) async {
    final state = _NoiseHandshakeState.initialize(initiator: initiator);
    final staticKeyPair = await _x25519.newKeyPair();
    final staticKeyPairData = await staticKeyPair.extract();
    final staticPublicKey = staticKeyPairData.publicKey.bytes;

    if (initiator) {
      state.localEphemeral = await (await _x25519.newKeyPair()).extract();
      final firstMessage = state.writeMessage(
        localStatic: staticKeyPairData,
        payload: Uint8List(0),
      );
      _writeNoiseFrame(io, firstMessage);

      final secondMessage = await _readNoiseFrame(
        io,
        timeout: handshakeTimeout,
      );
      final responderPayload = state.readMessage(
        secondMessage,
        localStatic: staticKeyPairData,
      );
      final responderIdentity = await _parseHandshakePayload(
        responderPayload,
        state.remoteStaticPublicKey!,
      );

      final thirdMessage = state.writeMessage(
        localStatic: staticKeyPairData,
        payload: await _buildHandshakePayload(staticPublicKey),
      );
      _writeNoiseFrame(io, thirdMessage);

      final transport = state.split(localRoleInitiator: true);
      return NoiseHandshakeResult(
        connection: _NoiseConnection(io, transport),
        remotePeerId: responderIdentity.peerId,
        remotePublicKey: responderIdentity.publicKey,
      );
    }

    final firstMessage = await _readNoiseFrame(
      io,
      timeout: handshakeTimeout,
    );
    state.readMessage(firstMessage, localStatic: staticKeyPairData);

    state.localEphemeral = await (await _x25519.newKeyPair()).extract();
    final secondMessage = state.writeMessage(
      localStatic: staticKeyPairData,
      payload: await _buildHandshakePayload(staticPublicKey),
    );
    _writeNoiseFrame(io, secondMessage);

    final thirdMessage = await _readNoiseFrame(
      io,
      timeout: handshakeTimeout,
    );
    final initiatorPayload = state.readMessage(
      thirdMessage,
      localStatic: staticKeyPairData,
    );
    final initiatorIdentity = await _parseHandshakePayload(
      initiatorPayload,
      state.remoteStaticPublicKey!,
    );

    final transport = state.split(localRoleInitiator: false);
    return NoiseHandshakeResult(
      connection: _NoiseConnection(io, transport),
      remotePeerId: initiatorIdentity.peerId,
      remotePublicKey: initiatorIdentity.publicKey,
    );
  }

  Future<Uint8List> _buildHandshakePayload(List<int> staticPublicKey) async {
    final identityKey = PeerId.marshalPublicKey(
      KeyType.ed25519,
      localKeyPair.publicKeyBytes,
    );
    final signature = await localKeyPair.sign([
      ..._prefixBytes,
      ...staticPublicKey,
    ]);
    return Uint8List.fromList([
      ...protoBytes(1, identityKey),
      ...protoBytes(2, signature),
    ]);
  }

  Future<_RemoteIdentity> _parseHandshakePayload(
    Uint8List payload,
    Uint8List remoteStaticPublicKey,
  ) async {
    Uint8List? identityKeyBytes;
    Uint8List? identitySig;

    var offset = 0;
    while (offset < payload.length) {
      final key = _readVarint(payload, offset);
      offset += key.length;
      final fieldNumber = key.value >> 3;
      final wireType = key.value & 0x07;
      if (wireType != 2) {
        throw FormatException('unsupported noise payload wire type: $wireType');
      }
      final length = _readVarint(payload, offset);
      offset += length.length;
      final value = Uint8List.fromList(
        payload.sublist(offset, offset + length.value),
      );
      offset += length.value;

      if (fieldNumber == 1) {
        identityKeyBytes = value;
      } else if (fieldNumber == 2) {
        identitySig = value;
      }
    }

    if (identityKeyBytes == null || identitySig == null) {
      throw const FormatException('noise handshake payload is incomplete');
    }

    final publicKey = _parseEd25519PublicKey(identityKeyBytes);
    final verified = await Libp2pKeyPair.verifyEd25519(
      message: [..._prefixBytes, ...remoteStaticPublicKey],
      signatureBytes: identitySig,
      publicKeyBytes: publicKey,
    );
    if (!verified) {
      throw StateError('noise handshake signature verification failed');
    }

    return _RemoteIdentity(
      PeerId.fromPublicKey(KeyType.ed25519, publicKey),
      publicKey,
    );
  }

  Uint8List _parseEd25519PublicKey(Uint8List bytes) {
    int? keyType;
    Uint8List? data;

    var offset = 0;
    while (offset < bytes.length) {
      final key = _readVarint(bytes, offset);
      offset += key.length;
      final fieldNumber = key.value >> 3;
      final wireType = key.value & 0x07;
      if (wireType == 0) {
        final value = _readVarint(bytes, offset);
        offset += value.length;
        if (fieldNumber == 1) {
          keyType = value.value;
        }
      } else if (wireType == 2) {
        final length = _readVarint(bytes, offset);
        offset += length.length;
        final value = Uint8List.fromList(
          bytes.sublist(offset, offset + length.value),
        );
        offset += length.value;
        if (fieldNumber == 2) {
          data = value;
        }
      } else {
        throw FormatException('unsupported public key wire type: $wireType');
      }
    }

    if (keyType != KeyType.ed25519.code || data == null) {
      throw const FormatException('only Ed25519 identity keys are supported');
    }
    return data;
  }
}

class _NoiseConnection implements ConnectionIO {
  _NoiseConnection(this._inner, this._transport)
      : _incomingController = StreamController<Uint8List>.broadcast() {
    _readLoop();
  }

  final ConnectionIO _inner;
  final _NoiseTransportState _transport;
  final StreamController<Uint8List> _incomingController;
  @override
  Stream<Uint8List> get input => _incomingController.stream;
  @override
  late final ByteReader reader = ByteReader(input);

  @override
  void send(Uint8List bytes) {
    if (bytes.length > NoiseProtocol.maxTransportMessageSize) {
      throw StateError(
        'noise transport message exceeds ${NoiseProtocol.maxTransportMessageSize} bytes',
      );
    }
    final encrypted = _transport.encrypt(bytes);
    final frame = Uint8List(2 + encrypted.length)
      ..buffer.asByteData().setUint16(0, encrypted.length)
      ..setRange(2, 2 + encrypted.length, encrypted);
    _inner.send(frame);
  }

  @override
  Future<void> close() async {
    await _incomingController.close();
    await _inner.close();
  }

  Future<void> _readLoop() async {
    try {
      while (true) {
        final lengthBytes = await _inner.reader.readExact(2);
        final length = ByteData.sublistView(lengthBytes).getUint16(0);
        if (length == 0 || length > 0xffff) {
          throw StateError('invalid noise frame length: $length');
        }
        final encrypted = await _inner.reader.readExact(length);
        final clearText = _transport.decrypt(encrypted);
        _incomingController.add(clearText);
      }
    } catch (error, stackTrace) {
      if (!_incomingController.isClosed) {
        _incomingController.addError(error, stackTrace);
        await _incomingController.close();
      }
    }
  }
}

class _NoiseHandshakeState {
  _NoiseHandshakeState._({
    required this.initiator,
    required Uint8List chainingKey,
    required Uint8List handshakeHash,
  })  : _chainingKey = chainingKey,
        _handshakeHash = handshakeHash;

  final bool initiator;
  Uint8List _chainingKey;
  Uint8List _handshakeHash;
  _CipherState? _cipherState;
  SimpleKeyPairData? localEphemeral;
  Uint8List? remoteEphemeralPublicKey;
  Uint8List? remoteStaticPublicKey;

  static _NoiseHandshakeState initialize({required bool initiator}) {
    final protocolHash = _sha256(NoiseProtocol._protocolName);
    return _NoiseHandshakeState._(
      initiator: initiator,
      chainingKey: protocolHash,
      handshakeHash: protocolHash,
    );
  }

  Uint8List writeMessage({
    required SimpleKeyPairData localStatic,
    required Uint8List payload,
  }) {
    if (initiator) {
      if (remoteEphemeralPublicKey == null) {
        return _writeMessage1(payload);
      }
      return _writeMessage3(localStatic, payload);
    }

    if (localEphemeral == null) {
      throw StateError('responder ephemeral key is missing');
    }
    return _writeMessage2(localStatic, payload);
  }

  Uint8List readMessage(
    Uint8List message, {
    required SimpleKeyPairData localStatic,
  }) {
    if (initiator) {
      return _readMessage2(message, localStatic);
    }
    if (remoteEphemeralPublicKey == null) {
      return _readMessage1(message);
    }
    return _readMessage3(message, localStatic);
  }

  _NoiseTransportState split({required bool localRoleInitiator}) {
    final outputs = _hkdf(_chainingKey, const [], 2);
    final first = _CipherState(outputs[0]);
    final second = _CipherState(outputs[1]);
    return localRoleInitiator
        ? _NoiseTransportState(sendCipher: first, receiveCipher: second)
        : _NoiseTransportState(sendCipher: second, receiveCipher: first);
  }

  Uint8List _writeMessage1(Uint8List payload) {
    final localEphemeral = this.localEphemeral;
    if (localEphemeral == null) {
      throw StateError('initiator ephemeral key is missing');
    }
    final message = <int>[];
    final ephemeralPublicKey = localEphemeral.publicKey.bytes;
    message.addAll(ephemeralPublicKey);
    _mixHash(ephemeralPublicKey);
    message.addAll(_encryptAndHash(payload));
    return Uint8List.fromList(message);
  }

  Uint8List _writeMessage2(SimpleKeyPairData localStatic, Uint8List payload) {
    final message = <int>[];
    final localEphemeral = this.localEphemeral;
    final remoteEphemeralPublicKey = this.remoteEphemeralPublicKey;
    if (localEphemeral == null || remoteEphemeralPublicKey == null) {
      throw StateError('message 2 requires local and remote ephemeral keys');
    }

    final ephemeralPublicKey = localEphemeral.publicKey.bytes;
    message.addAll(ephemeralPublicKey);
    _mixHash(ephemeralPublicKey);
    _mixKey(_dh(localEphemeral, remoteEphemeralPublicKey));

    final localStaticPublicKey = localStatic.publicKey.bytes;
    message.addAll(_encryptAndHash(localStaticPublicKey));
    _mixKey(_dh(localStatic, remoteEphemeralPublicKey));
    message.addAll(_encryptAndHash(payload));
    return Uint8List.fromList(message);
  }

  Uint8List _writeMessage3(SimpleKeyPairData localStatic, Uint8List payload) {
    final message = <int>[];
    final remoteEphemeralPublicKey = this.remoteEphemeralPublicKey;
    if (remoteEphemeralPublicKey == null) {
      throw StateError('message 3 requires remote ephemeral key');
    }

    final localStaticPublicKey = localStatic.publicKey.bytes;
    message.addAll(_encryptAndHash(localStaticPublicKey));
    _mixKey(_dh(localStatic, remoteEphemeralPublicKey));
    message.addAll(_encryptAndHash(payload));
    return Uint8List.fromList(message);
  }

  Uint8List _readMessage1(Uint8List message) {
    if (message.length < 32) {
      throw const FormatException('noise message 1 is too short');
    }
    remoteEphemeralPublicKey = Uint8List.fromList(message.sublist(0, 32));
    _mixHash(remoteEphemeralPublicKey!);
    return _decryptAndHash(Uint8List.fromList(message.sublist(32)));
  }

  Uint8List _readMessage2(Uint8List message, SimpleKeyPairData localStatic) {
    if (message.length < 32 + 48) {
      throw const FormatException('noise message 2 is too short');
    }
    var offset = 0;
    remoteEphemeralPublicKey = Uint8List.fromList(message.sublist(offset, offset + 32));
    offset += 32;
    _mixHash(remoteEphemeralPublicKey!);

    final localEphemeral = this.localEphemeral;
    if (localEphemeral == null) {
      throw StateError('initiator ephemeral key is missing');
    }
    _mixKey(_dh(localEphemeral, remoteEphemeralPublicKey!));

    final encryptedStatic = Uint8List.fromList(message.sublist(offset, offset + 48));
    offset += 48;
    remoteStaticPublicKey = _decryptAndHash(encryptedStatic);
    _mixKey(_dh(localEphemeral, remoteStaticPublicKey!));

    final payload = Uint8List.fromList(message.sublist(offset));
    return _decryptAndHash(payload);
  }

  Uint8List _readMessage3(Uint8List message, SimpleKeyPairData localStatic) {
    if (message.length < 48) {
      throw const FormatException('noise message 3 is too short');
    }
    var offset = 0;
    final encryptedStatic = Uint8List.fromList(message.sublist(offset, offset + 48));
    offset += 48;
    remoteStaticPublicKey = _decryptAndHash(encryptedStatic);
    final localEphemeral = this.localEphemeral;
    if (localEphemeral == null) {
      throw StateError('message 3 requires local ephemeral key');
    }
    _mixKey(_dh(localEphemeral, remoteStaticPublicKey!));

    final payload = Uint8List.fromList(message.sublist(offset));
    return _decryptAndHash(payload);
  }

  void _mixHash(List<int> data) {
    _handshakeHash = _sha256([..._handshakeHash, ...data]);
  }

  void _mixKey(List<int> inputKeyMaterial) {
    final outputs = _hkdf(_chainingKey, inputKeyMaterial, 2);
    _chainingKey = outputs[0];
    _cipherState = _CipherState(outputs[1]);
  }

  Uint8List _encryptAndHash(List<int> plainText) {
    final cipherState = _cipherState;
    if (cipherState == null) {
      _mixHash(plainText);
      return Uint8List.fromList(plainText);
    }
    final cipherText = cipherState.encrypt(
      plainText,
      aad: _handshakeHash,
    );
    _mixHash(cipherText);
    return cipherText;
  }

  Uint8List _decryptAndHash(List<int> cipherText) {
    final cipherState = _cipherState;
    if (cipherState == null) {
      _mixHash(cipherText);
      return Uint8List.fromList(cipherText);
    }
    final plainText = cipherState.decrypt(
      cipherText,
      aad: _handshakeHash,
    );
    _mixHash(cipherText);
    return plainText;
  }

  Uint8List _dh(SimpleKeyPairData localKeyPair, List<int> remotePublicKeyBytes) {
    final sharedSecret = NoiseProtocol._x25519.sharedSecretSync(
      keyPairData: localKeyPair,
      remotePublicKey: SimplePublicKey(
        remotePublicKeyBytes,
        type: KeyPairType.x25519,
      ),
    );
    return Uint8List.fromList((sharedSecret as SecretKeyData).bytes);
  }
}

class _NoiseTransportState {
  _NoiseTransportState({
    required this.sendCipher,
    required this.receiveCipher,
  });

  final _CipherState sendCipher;
  final _CipherState receiveCipher;

  Uint8List encrypt(List<int> plainText) => sendCipher.encrypt(plainText);

  Uint8List decrypt(List<int> cipherText) => receiveCipher.decrypt(cipherText);
}

class _CipherState {
  _CipherState(List<int> key)
      : _key = SecretKeyData(Uint8List.fromList(key)),
        _nonce = 0;

  final SecretKeyData _key;
  int _nonce;

  Uint8List encrypt(List<int> plainText, {List<int> aad = const []}) {
    final secretBox = NoiseProtocol._cipher.encryptSync(
      plainText,
      secretKey: _key,
      nonce: _nonceBytes(_nonce),
      aad: aad,
    );
    _nonce++;
    return Uint8List.fromList([...secretBox.cipherText, ...secretBox.mac.bytes]);
  }

  Uint8List decrypt(List<int> cipherText, {List<int> aad = const []}) {
    if (cipherText.length < 16) {
      throw const FormatException('noise ciphertext is too short');
    }
    final macOffset = cipherText.length - 16;
    final clearText = NoiseProtocol._cipher.decryptSync(
      SecretBox(
        cipherText.sublist(0, macOffset),
        nonce: _nonceBytes(_nonce),
        mac: Mac(cipherText.sublist(macOffset)),
      ),
      secretKey: _key,
      aad: aad,
    );
    _nonce++;
    return Uint8List.fromList(clearText);
  }
}

class _RemoteIdentity {
  _RemoteIdentity(this.peerId, this.publicKey);

  final PeerId peerId;
  final Uint8List publicKey;
}

void _writeNoiseFrame(ConnectionIO io, List<int> payload) {
  if (payload.length > 0xffff) {
    throw ArgumentError('noise frame is too large');
  }
  final frame = Uint8List(2 + payload.length)
    ..buffer.asByteData().setUint16(0, payload.length)
    ..setRange(2, 2 + payload.length, payload);
  io.send(frame);
}

Future<Uint8List> _readNoiseFrame(
  ConnectionIO io, {
  Duration? timeout,
}) async {
  final lengthBytes = await io.reader
      .readExact(2)
      .timeout(timeout ?? NoiseProtocol.handshakeTimeout);
  final length = ByteData.sublistView(lengthBytes).getUint16(0);
  if (length == 0 || length > 0xffff) {
    throw StateError('invalid noise frame length: $length');
  }
  return io.reader.readExact(length).timeout(
        timeout ?? NoiseProtocol.handshakeTimeout,
      );
}

Uint8List _sha256(List<int> input) =>
    Uint8List.fromList(crypto.sha256.convert(input).bytes);

List<Uint8List> _hkdf(List<int> chainingKey, List<int> inputKeyMaterial, int count) {
  final prk = crypto
      .Hmac(crypto.sha256, chainingKey)
      .convert(inputKeyMaterial)
      .bytes;
  final outputs = <Uint8List>[];
  var previous = <int>[];
  for (var i = 1; i <= count; i++) {
    previous = crypto.Hmac(crypto.sha256, prk).convert([...previous, i]).bytes;
    outputs.add(Uint8List.fromList(previous));
  }
  return outputs;
}

Uint8List _nonceBytes(int nonce) {
  final bytes = Uint8List(12);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, 0, Endian.little);
  data.setUint64(4, nonce, Endian.little);
  return bytes;
}

class _VarintResult {
  _VarintResult(this.value, this.length);

  final int value;
  final int length;
}

_VarintResult _readVarint(List<int> bytes, int offset) {
  var shift = 0;
  var value = 0;
  var index = offset;
  while (index < bytes.length) {
    final byte = bytes[index];
    value |= (byte & 0x7f) << shift;
    index++;
    if ((byte & 0x80) == 0) {
      return _VarintResult(value, index - offset);
    }
    shift += 7;
  }
  throw const FormatException('incomplete varint');
}
