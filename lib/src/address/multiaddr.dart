import 'dart:convert';
import 'dart:typed_data';

import '../crypto/base58.dart';
import '../crypto/varint.dart';

class _Protocol {
  const _Protocol(this.name, this.code, this.size);

  final String name;
  final int code;
  final int size;
}

const _protocolsByName = <String, _Protocol>{
  'ip4': _Protocol('ip4', 0x04, 32),
  'tcp': _Protocol('tcp', 0x06, 16),
  'dns4': _Protocol('dns4', 0x36, -1),
  'dns6': _Protocol('dns6', 0x37, -1),
  'dnsaddr': _Protocol('dnsaddr', 0x38, -1),
  'ip6': _Protocol('ip6', 0x29, 128),
  'p2p': _Protocol('p2p', 0x01a5, -1),
};

final _protocolsByCode = <int, _Protocol>{
  for (final entry in _protocolsByName.values) entry.code: entry,
};

class MultiaddrComponent {
  const MultiaddrComponent(this.protocol, this.value);

  final String protocol;
  final String? value;
}

class Multiaddr {
  Multiaddr(this.components);

  final List<MultiaddrComponent> components;

  factory Multiaddr.parse(String value) {
    if (!value.startsWith('/')) {
      throw FormatException('multiaddr must start with "/"');
    }

    final segments = value
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList();
    final components = <MultiaddrComponent>[];
    for (var index = 0; index < segments.length; index++) {
      final protocol = segments[index];
      final definition = _protocolsByName[protocol];
      if (definition == null) {
        throw FormatException('unsupported protocol: $protocol');
      }
      String? componentValue;
      if (definition.size != 0) {
        index++;
        if (index >= segments.length) {
          throw FormatException('missing value for protocol: $protocol');
        }
        componentValue = segments[index];
      }
      components.add(MultiaddrComponent(protocol, componentValue));
    }
    return Multiaddr(components);
  }

  factory Multiaddr.fromBytes(Uint8List bytes) {
    final components = <MultiaddrComponent>[];
    var offset = 0;
    while (offset < bytes.length) {
      final protocolCode = decodeUVarint(bytes, offset);
      offset += protocolCode.length;
      final protocol = _protocolsByCode[protocolCode.value];
      if (protocol == null) {
        throw FormatException(
          'unsupported protocol code: ${protocolCode.value}',
        );
      }
      String? value;
      if (protocol.size != 0) {
        if (protocol.size > 0) {
          final sizeInBytes = protocol.size ~/ 8;
          final raw = bytes.sublist(offset, offset + sizeInBytes);
          offset += sizeInBytes;
          value = _decodeFixedValue(protocol.name, raw);
        } else {
          final length = decodeUVarint(bytes, offset);
          offset += length.length;
          final raw = bytes.sublist(offset, offset + length.value);
          offset += length.value;
          value = _decodeVariableValue(protocol.name, raw);
        }
      }
      components.add(MultiaddrComponent(protocol.name, value));
    }
    return Multiaddr(components);
  }

  Uint8List toBytes() {
    final out = <int>[];
    for (final component in components) {
      final protocol = _protocolsByName[component.protocol];
      if (protocol == null) {
        throw FormatException('unsupported protocol: ${component.protocol}');
      }
      out.addAll(encodeUVarint(protocol.code));
      if (protocol.size == 0) {
        continue;
      }
      final value = component.value;
      if (value == null) {
        throw FormatException(
          'missing value for protocol ${component.protocol}',
        );
      }
      if (protocol.size > 0) {
        out.addAll(_encodeFixedValue(component.protocol, value));
      } else {
        final raw = _encodeVariableValue(component.protocol, value);
        out.addAll(encodeUVarint(raw.length));
        out.addAll(raw);
      }
    }
    return Uint8List.fromList(out);
  }

  String? valueForProtocol(String protocol) {
    for (final component in components) {
      if (component.protocol == protocol) {
        return component.value;
      }
    }
    return null;
  }

  @override
  String toString() {
    final buffer = StringBuffer();
    for (final component in components) {
      buffer.write('/${component.protocol}');
      if (component.value != null) {
        buffer.write('/${component.value}');
      }
    }
    return buffer.toString();
  }

  static Uint8List _encodeFixedValue(String protocol, String value) {
    switch (protocol) {
      case 'ip4':
        final parts = value.split('.');
        if (parts.length != 4) {
          throw FormatException('invalid ip4 address: $value');
        }
        return Uint8List.fromList(parts.map(int.parse).toList(growable: false));
      case 'tcp':
        final port = int.parse(value);
        return Uint8List.fromList([(port >> 8) & 0xff, port & 0xff]);
      case 'ip6':
        throw UnimplementedError('ip6 binary encoding is not implemented yet');
      default:
        throw FormatException('unsupported fixed-size protocol: $protocol');
    }
  }

  static String _decodeFixedValue(String protocol, List<int> raw) {
    switch (protocol) {
      case 'ip4':
        return raw.join('.');
      case 'tcp':
        final port = (raw[0] << 8) | raw[1];
        return '$port';
      case 'ip6':
        throw UnimplementedError('ip6 binary decoding is not implemented yet');
      default:
        throw FormatException('unsupported fixed-size protocol: $protocol');
    }
  }

  static Uint8List _encodeVariableValue(String protocol, String value) {
    switch (protocol) {
      case 'dns4':
      case 'dns6':
      case 'dnsaddr':
        return Uint8List.fromList(utf8.encode(value));
      case 'p2p':
        return decodeBase58(value);
      default:
        throw FormatException('unsupported variable-size protocol: $protocol');
    }
  }

  static String _decodeVariableValue(String protocol, List<int> raw) {
    switch (protocol) {
      case 'dns4':
      case 'dns6':
      case 'dnsaddr':
        return utf8.decode(raw);
      case 'p2p':
        return encodeBase58(Uint8List.fromList(raw));
      default:
        throw FormatException('unsupported variable-size protocol: $protocol');
    }
  }
}
