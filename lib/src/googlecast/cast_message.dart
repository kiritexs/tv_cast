import 'dart:convert';
import 'dart:typed_data';

/// One message on a Google Cast channel (CASTV2): who sends it, to whom, on
/// which namespace, and its JSON payload. On the wire it is the
/// `CastMessage` protocol buffer after a four-byte big-endian length; only
/// string payloads are used.
class CastMessage {
  const CastMessage({
    required this.source,
    required this.destination,
    required this.namespace,
    required this.payload,
  });

  final String source;
  final String destination;
  final String namespace;
  final String payload;

  /// The payload as JSON; empty when it isn't an object.
  Map<String, Object?> get json {
    try {
      final value = jsonDecode(payload);
      return value is Map<String, Object?> ? value : const {};
    } on FormatException {
      return const {};
    }
  }

  /// The protocol buffer, without the length.
  Uint8List encode() {
    final out = BytesBuilder()
      ..add([0x08, 0x00]) // protocol_version = CASTV2_1_0
      ..add(_string(2, source))
      ..add(_string(3, destination))
      ..add(_string(4, namespace))
      ..add([0x28, 0x00]) // payload_type = STRING
      ..add(_string(6, payload));
    return out.toBytes();
  }

  /// The length, then the protocol buffer.
  Uint8List frame() {
    final body = encode();
    return (BytesBuilder()
          ..add([
            (body.length >> 24) & 0xFF,
            (body.length >> 16) & 0xFF,
            (body.length >> 8) & 0xFF,
            body.length & 0xFF,
          ])
          ..add(body))
        .toBytes();
  }

  /// Reads a protocol buffer; fields it doesn't know are skipped. Throws
  /// [FormatException] on a broken one, and every step moves forward
  /// within [bytes]: no frame can send the reader back or past the end.
  static CastMessage decode(Uint8List bytes) {
    final strings = <int, String>{};
    var at = 0;
    void need(int length) {
      if (bytes.length - at < length) {
        throw const FormatException('cast: cut short');
      }
    }

    // At most ten bytes; one that sets the sign bit is no length or key.
    int varint() {
      var value = 0;
      for (var shift = 0; shift < 64; shift += 7) {
        need(1);
        final b = bytes[at++];
        value |= (b & 0x7F) << shift;
        if (b & 0x80 == 0) {
          if (value < 0) throw const FormatException('cast: bad varint');
          return value;
        }
      }
      throw const FormatException('cast: bad varint');
    }

    while (at < bytes.length) {
      final key = varint();
      final field = key >> 3;
      switch (key & 7) {
        case 0:
          varint();
        case 2:
          final length = varint();
          need(length);
          if (field >= 2 && field <= 6) {
            strings[field] = utf8.decode(
              bytes.sublist(at, at + length),
              allowMalformed: true,
            );
          }
          at += length;
        case 1:
          need(8);
          at += 8;
        case 5:
          need(4);
          at += 4;
        default:
          throw const FormatException('cast: bad wire type');
      }
    }
    return CastMessage(
      source: strings[2] ?? '',
      destination: strings[3] ?? '',
      namespace: strings[4] ?? '',
      payload: strings[6] ?? '',
    );
  }

  static List<int> _string(int field, String value) {
    final bytes = utf8.encode(value);
    return [(field << 3) | 2, ..._varint(bytes.length), ...bytes];
  }

  static List<int> _varint(int value) {
    final out = <int>[];
    var v = value;
    while (v >= 0x80) {
      out.add((v & 0x7F) | 0x80);
      v >>= 7;
    }
    out.add(v);
    return out;
  }

  @override
  String toString() => 'CastMessage($source → $destination, $namespace)';
}

/// Splits a byte stream into [CastMessage]s.
class CastFrameReader {
  final _buffer = BytesBuilder();

  /// The messages complete once [chunk] is added.
  List<CastMessage> add(List<int> chunk) {
    _buffer.add(chunk);
    final messages = <CastMessage>[];
    final bytes = _buffer.takeBytes();
    var at = 0;
    while (bytes.length - at >= 4) {
      final length =
          (bytes[at] << 24) |
          (bytes[at + 1] << 16) |
          (bytes[at + 2] << 8) |
          bytes[at + 3];
      if (length > 1 << 20) throw const FormatException('cast: frame too big');
      if (bytes.length - at - 4 < length) break;
      messages.add(
        CastMessage.decode(
          Uint8List.sublistView(bytes, at + 4, at + 4 + length),
        ),
      );
      at += 4 + length;
    }
    if (at < bytes.length) _buffer.add(bytes.sublist(at));
    return messages;
  }
}
