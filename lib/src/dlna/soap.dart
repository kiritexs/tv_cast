import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

import '../cast_device.dart';

/// Calls UPnP actions over SOAP.
class SoapClient {
  SoapClient({this.timeout = const Duration(seconds: 8)});

  final Duration timeout;

  /// Calls [action] of [service] (e.g. `AVTransport`) at [control] with
  /// [args] in order; the response element's children by name. A fault or a
  /// failure to reach it throws [CastException].
  Future<Map<String, String>> call(
    Uri control,
    String service,
    String action,
    List<(String, String)> args,
  ) async {
    final type = 'urn:schemas-upnp-org:service:$service:1';
    final body = StringBuffer()
      ..write('<?xml version="1.0" encoding="utf-8"?>')
      ..write(
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" ',
      )
      ..write('s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">')
      ..write('<s:Body><u:$action xmlns:u="$type">');
    for (final (name, value) in args) {
      body.write('<$name>${xmlEscape(value)}</$name>');
    }
    body.write('</u:$action></s:Body></s:Envelope>');

    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.postUrl(control).timeout(timeout);
      req.headers.set('Content-Type', 'text/xml; charset="utf-8"');
      req.headers.set('SOAPACTION', '"$type#$action"');
      // With its length, not chunked: some UPnP stacks refuse that; and a
      // reply read leniently, since some TVs echo a title back in Latin-1.
      final bytes = utf8.encode(body.toString());
      req.contentLength = bytes.length;
      req.add(bytes);
      final res = await req.close().timeout(timeout);
      final text = await res.transform(lenientUtf8).join().timeout(timeout);
      if (res.statusCode != 200) {
        throw _fault(action, res.statusCode, text);
      }
      return _response(text, action);
    } on CastException {
      rethrow;
    } on TimeoutException {
      throw CastException(action, 'no answer');
    } on IOException catch (e) {
      throw CastException(action, 'unreachable: $e');
    } finally {
      client.close(force: true);
    }
  }

  static Map<String, String> _response(String text, String action) {
    try {
      final doc = XmlDocument.parse(text);
      final element = doc.descendantElements.firstWhere(
        (e) => e.localName == '${action}Response',
      );
      return {
        for (final child in element.childElements)
          child.localName: child.innerText,
      };
    } on StateError {
      return const {};
    } on XmlException {
      return const {};
    }
  }

  static CastException _fault(String action, int status, String text) {
    String? code;
    String? description;
    try {
      final doc = XmlDocument.parse(text);
      code = doc.descendantElements
          .where((e) => e.localName == 'errorCode')
          .firstOrNull
          ?.innerText;
      description = doc.descendantElements
          .where((e) => e.localName == 'errorDescription')
          .firstOrNull
          ?.innerText;
    } on XmlException {
      // Not a SOAP fault: the status says it.
    }
    return CastException(
      action,
      description?.trim().isNotEmpty == true ? description!.trim() : 'refused',
      status: status,
      code: int.tryParse(code?.trim() ?? ''),
    );
  }
}

/// A TV's text as UTF-8, a byte that isn't read as U+FFFD instead of
/// throwing: some TVs answer in Latin-1 under a UTF-8 header.
const lenientUtf8 = Utf8Decoder(allowMalformed: true);

/// Characters XML 1.0 doesn't allow (controls other than tab and line
/// breaks): some TVs refuse a whole SetAVTransportURI over one in a title.
final _notXml = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\uFFFE\uFFFF]');

/// [text] escaped for an XML element or attribute.
String xmlEscape(String text) => text
    .replaceAll(_notXml, '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// A time as UPnP writes it: `HH:MM:SS`.
String formatUpnpTime(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(s ~/ 3600)}:${two(s ~/ 60 % 60)}:${two(s % 60)}';
}

/// A UPnP time (`H+:MM:SS[.F+]`); null when it isn't one, e.g.
/// `NOT_IMPLEMENTED`.
Duration? parseUpnpTime(String? text) {
  final m = RegExp(
    r'^\s*(\d+):(\d{1,2}):(\d{1,2})(?:\.(\d+))?',
  ).firstMatch(text ?? '');
  if (m == null) return null;
  final fraction = m[4] == null
      ? 0
      : (double.parse('0.${m[4]}') * 1000).round();
  return Duration(
    hours: int.parse(m[1]!),
    minutes: int.parse(m[2]!),
    seconds: int.parse(m[3]!),
    milliseconds: fraction,
  );
}

/// What DLNA renderers are told about a video served over HTTP: playable
/// from any byte (`OP=01`), and streamed (`FLAGS=017…`).
const dlnaContentFeatures =
    'DLNA.ORG_OP=01;DLNA.ORG_CI=0;'
    'DLNA.ORG_FLAGS=01700000000000000000000000000000';

/// The DIDL-Lite metadata a renderer gets with a URL.
String didlLite({
  required Uri url,
  required String title,
  required String contentType,
  int? sizeBytes,
}) {
  final size = sizeBytes == null ? '' : ' size="$sizeBytes"';
  return '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/" '
      'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
      '<item id="1" parentID="0" restricted="1">'
      '<dc:title>${xmlEscape(title)}</dc:title>'
      '<upnp:class>object.item.videoItem</upnp:class>'
      '<res protocolInfo="http-get:*:${xmlEscape(contentType)}:'
      '$dlnaContentFeatures"$size>${xmlEscape(url.toString())}</res>'
      '</item></DIDL-Lite>';
}
