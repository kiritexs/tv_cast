import 'dart:convert';
import 'dart:typed_data';

/// The little of DNS that finding Google Cast devices needs (RFC 1035, and
/// mDNS's RFC 6762): a question for one name and type, and the records of
/// an answer.
abstract final class DnsType {
  static const a = 1;
  static const ptr = 12;
  static const txt = 16;
  static const srv = 33;
}

/// One record of an answer; [data] is what its type carries.
class DnsRecord {
  const DnsRecord(this.name, this.type, this.data);

  final String name;
  final int type;

  /// PTR: the name it points to. SRV: `(port, target)`. TXT: its
  /// `key=value` pairs. A: the address's four bytes. Anything else: null.
  final Object? data;

  @override
  String toString() => 'DnsRecord($name, $type, $data)';
}

/// A query for [name] of [type], id 0, no flags.
Uint8List dnsQuery(String name, int type) {
  final out = BytesBuilder()
    ..add([0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]) // id, flags, 1 question
    ..add(_encodeName(name))
    ..add([type >> 8, type & 0xFF, 0, 1]); // type, class IN
  return out.toBytes();
}

List<int> _encodeName(String name) => [
  for (final label in name.split('.').where((l) => l.isNotEmpty)) ...[
    utf8.encode(label).length,
    ...utf8.encode(label),
  ],
  0,
];

/// Every record of an answer (answers, authority and additional alike);
/// throws [FormatException] on a message it can't read.
List<DnsRecord> dnsRecords(Uint8List message) {
  final r = _Reader(message);
  r.skip(4); // id, flags
  final questions = r.u16();
  final records = r.u16() + r.u16() + r.u16();
  for (var i = 0; i < questions; i++) {
    r.name();
    r.skip(4);
  }
  return [for (var i = 0; i < records; i++) r.record()];
}

class _Reader {
  _Reader(this.bytes);

  final Uint8List bytes;
  int at = 0;

  void _need(int n) {
    if (at + n > bytes.length) throw const FormatException('DNS: cut short');
  }

  void skip(int n) {
    _need(n);
    at += n;
  }

  int u8() {
    _need(1);
    return bytes[at++];
  }

  int u16() => (u8() << 8) | u8();

  /// A name at the reader, following compression pointers.
  String name() {
    final labels = <String>[];
    var pos = at;
    var jumped = false;
    for (var hops = 0; hops < 64; hops++) {
      if (pos >= bytes.length) throw const FormatException('DNS: bad name');
      final len = bytes[pos];
      if (len == 0) {
        if (!jumped) at = pos + 1;
        return labels.join('.');
      }
      if (len & 0xC0 == 0xC0) {
        if (pos + 1 >= bytes.length) {
          throw const FormatException('DNS: bad name');
        }
        final target = ((len & 0x3F) << 8) | bytes[pos + 1];
        if (!jumped) at = pos + 2;
        jumped = true;
        pos = target;
        continue;
      }
      if (pos + 1 + len > bytes.length) {
        throw const FormatException('DNS: bad label');
      }
      labels.add(
        utf8.decode(
          bytes.sublist(pos + 1, pos + 1 + len),
          allowMalformed: true,
        ),
      );
      pos += 1 + len;
    }
    throw const FormatException('DNS: name loops');
  }

  DnsRecord record() {
    final owner = name();
    final type = u16();
    skip(2 + 4); // class, ttl
    final length = u16();
    _need(length);
    final end = at + length;
    final Object? data = switch (type) {
      DnsType.ptr => name(),
      DnsType.srv => () {
        skip(4); // priority, weight
        return (u16(), name());
      }(),
      DnsType.txt => _txt(end),
      DnsType.a when length == 4 => bytes.sublist(at, end),
      _ => null,
    };
    at = end;
    return DnsRecord(owner, type, data);
  }

  Map<String, String> _txt(int end) {
    final pairs = <String, String>{};
    while (at < end) {
      final len = u8();
      if (at + len > end) break;
      final entry = utf8.decode(
        bytes.sublist(at, at + len),
        allowMalformed: true,
      );
      at += len;
      final eq = entry.indexOf('=');
      if (eq > 0) {
        pairs[entry.substring(0, eq).toLowerCase()] = entry.substring(eq + 1);
      }
    }
    return pairs;
  }
}
