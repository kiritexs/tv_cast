/// The small parsers and writers: ranges, UPnP times and states, SSDP
/// answers, DIDL-Lite, device descriptions.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tv_cast/src/cast_device.dart';
import 'package:tv_cast/src/dlna/description.dart';
import 'package:tv_cast/src/dlna/dlna_renderer.dart';
import 'package:tv_cast/src/dlna/soap.dart';
import 'package:tv_cast/src/dlna/ssdp.dart';
import 'package:tv_cast/src/relay/byte_range.dart';

void main() {
  group('ranges', () {
    test('open, closed, suffix, and none', () {
      expect(parseRange(null, 1000), isNull);
      expect(parseRange('bytes=0-', 1000), const ByteRange(0, 999, 1000));
      expect(
        parseRange('bytes=100-199', 1000),
        const ByteRange(100, 199, 1000),
      );
      expect(
        parseRange('bytes=900-5000', 1000),
        const ByteRange(900, 999, 1000),
      );
      expect(parseRange('bytes=-100', 1000), const ByteRange(900, 999, 1000));
      expect(parseRange('bytes=-5000', 1000), const ByteRange(0, 999, 1000));
      expect(parseRange('bytes=0-0', 1000)!.length, 1);
      expect(
        parseRange('bytes=275446478-', 275446554)!.contentRange,
        'bytes 275446478-275446553/275446554',
      );
    });

    test('past the end is 416; nonsense is the whole file', () {
      expect(
        () => parseRange('bytes=1000-', 1000),
        throwsA(isA<RangeNotSatisfiable>()),
      );
      expect(
        () => parseRange('bytes=-0', 1000),
        throwsA(isA<RangeNotSatisfiable>()),
      );
      expect(parseRange('items=0-10', 1000), isNull);
      expect(parseRange('bytes=50-10', 1000), isNull);
    });

    test('digits past what an int holds: past the end, never a '
        'FormatException (the relay\'s 502)', () {
      const huge = '99999999999999999999999999';
      expect(
        () => parseRange('bytes=$huge-', 1000),
        throwsA(isA<RangeNotSatisfiable>()),
      );
      expect(
        parseRange('bytes=10-$huge', 1000),
        const ByteRange(10, 999, 1000),
      );
      expect(parseRange('bytes=-$huge', 1000), const ByteRange(0, 999, 1000));
    });
  });

  test('a reading that fails any way is one missed reading, never the end '
      'of the watch', () async {
    final session = _Flaky();
    var closed = false;
    final first = await readingsOf(
      session,
      const Duration(milliseconds: 1),
      () => closed,
    ).first;
    closed = true;
    expect(first.state, CastState.playing);
    expect(session.polls, 2);
  });

  group('UPnP', () {
    test('a title\'s control characters are dropped, not sent to the TV', () {
      expect(
        xmlEscape('Ep\u0001 1\u0008 <A&B>\tok'),
        'Ep 1 &lt;A&amp;B&gt;\tok',
      );
    });

    test('times both ways', () {
      expect(formatUpnpTime(const Duration(minutes: 5)), '00:05:00');
      expect(formatUpnpTime(const Duration(hours: 1, seconds: 7)), '01:00:07');
      expect(formatUpnpTime(const Duration(seconds: -3)), '00:00:00');
      expect(parseUpnpTime('0:23:04'), const Duration(minutes: 23, seconds: 4));
      expect(
        parseUpnpTime('00:10:35.500'),
        const Duration(minutes: 10, seconds: 35, milliseconds: 500),
      );
      expect(parseUpnpTime('NOT_IMPLEMENTED'), isNull);
      expect(parseUpnpTime(null), isNull);
    });

    test('transport states', () {
      expect(castStateOf('PLAYING'), CastState.playing);
      expect(castStateOf('PAUSED_PLAYBACK'), CastState.paused);
      expect(castStateOf('TRANSITIONING'), CastState.loading);
      expect(castStateOf('STOPPED'), CastState.stopped);
      expect(castStateOf('NO_MEDIA_PRESENT'), CastState.idle);
      expect(castStateOf('CUSTOM'), CastState.unknown);
    });

    test('DIDL-Lite escapes the title and URL, and says what the video is', () {
      final didl = didlLite(
        url: Uri.parse('http://192.168.1.17:5000/abc/video.mp4?a=1&b=2'),
        title: 'Tom & Jerry <EP 1>',
        contentType: 'video/mp4',
        sizeBytes: 42,
      );
      expect(
        didl,
        contains('<dc:title>Tom &amp; Jerry &lt;EP 1&gt;</dc:title>'),
      );
      expect(didl, contains('video.mp4?a=1&amp;b=2</res>'));
      expect(
        didl,
        contains('protocolInfo="http-get:*:video/mp4:DLNA.ORG_OP=01'),
      );
      expect(didl, contains('size="42"'));
    });
  });

  group('SSDP', () {
    test('an answer\'s headers; anything else is not one', () {
      final headers = parseSsdpAnswer(
        'HTTP/1.1 200 OK\r\n'
        'CACHE-CONTROL: max-age=1800\r\n'
        'LOCATION: http://192.168.1.15:7676/smp_11_\r\n'
        'SERVER: SHP, UPnP/1.0, Samsung UPnP SDK/1.0\r\n'
        'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
        'USN: uuid:abc::urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n',
      );
      expect(headers!['location'], 'http://192.168.1.15:7676/smp_11_');
      expect(headers['server'], contains('Samsung'));
      expect(parseSsdpAnswer('NOTIFY * HTTP/1.1\r\nHOST: x\r\n\r\n'), isNull);
    });

    test('private addresses', () {
      for (final a in [
        '10.0.0.2',
        '172.16.0.1',
        '172.31.9.9',
        '192.168.1.17',
      ]) {
        expect(isPrivateIPv4(InternetAddress(a)), isTrue, reason: a);
      }
      for (final a in ['8.8.8.8', '172.32.0.1', '192.169.0.1', '127.0.0.1']) {
        expect(isPrivateIPv4(InternetAddress(a)), isFalse, reason: a);
      }
    });

    // Any answer could send the app's requests, and then its play commands
    // with the video's link, to any address.
    test("an answer's location is on this network, this device only from "
        'this device', () {
      SsdpAnswer? read(String location, String from) => readSsdpAnswer(
        'HTTP/1.1 200 OK\r\nLOCATION: $location\r\n\r\n',
        from: InternetAddress(from),
        via: InternetAddress('192.168.1.5'),
      );
      expect(read('http://192.168.1.15:7676/d', '192.168.1.15'), isNotNull);
      expect(read('http://169.254.3.4:7676/d', '169.254.3.4'), isNotNull);
      // This device's own address, named by another, is its services.
      expect(read('http://192.168.1.5:8080/d', '192.168.1.15'), isNull);
      expect(read('http://192.168.1.5:8080/d', '192.168.1.5'), isNotNull);
      expect(
        read('http://127.0.0.1:8080/d', '127.0.0.1'),
        isNotNull,
        reason: 'a renderer on this device',
      );
      // A TV answering on Wi-Fi may name its
      // Ethernet address.
      expect(
        read('http://192.168.1.21:9197/dmr', '192.168.1.20'),
        isNotNull,
        reason: 'another address on this network',
      );
      expect(
        read('http://127.0.0.1:8080/d', '192.168.1.15'),
        isNull,
        reason: 'this device, named by another',
      );
      expect(read('http://8.8.8.8/d', '8.8.8.8'), isNull, reason: 'internet');
      expect(
        read('https://192.168.1.15/d', '192.168.1.15'),
        isNull,
        reason: "not UPnP's http",
      );
      expect(
        read('http://tv.local:7676/d', '192.168.1.15'),
        isNull,
        reason: 'a name, not the address that answered',
      );
    });
  });

  group('device descriptions', () {
    final location = Uri.parse('http://192.168.1.15:7676/smp_11_');

    test('a Samsung TV\'s: name, maker, model, control URLs made absolute', () {
      final d = parseDescription(samsungDescription, location)!;
      expect(d.name, '[TV]Samsung LED49');
      expect(d.maker, 'Samsung Electronics');
      expect(d.model, 'UA49J5200 AllShare1.0');
      expect(d.udn, 'uuid:0ad8e2c0-0000-1000-0000-tv');
      expect(d.avTransport.toString(), 'http://192.168.1.15:7676/smp_19_');
      expect(
        d.connectionManager.toString(),
        'http://192.168.1.15:7676/smp_22_',
      );
      expect(d.renderingControl.toString(), 'http://192.168.1.15:7676/smp_16_');
    });

    test('URLBase wins over the location', () {
      final d = parseDescription(
        samsungDescription.replaceFirst(
          '<device>',
          '<URLBase>http://192.168.1.15:9197/</URLBase><device>',
        ),
        location,
      )!;
      expect(d.avTransport.toString(), 'http://192.168.1.15:9197/smp_19_');
    });

    // The control URLs, where the play commands go, could name any host.
    test('the control URLs stay on the renderer: a URLBase or a control URL '
        'elsewhere is ignored', () {
      final based = parseDescription(
        samsungDescription.replaceFirst(
          '<device>',
          '<URLBase>http://10.0.0.9:9197/</URLBase><device>',
        ),
        location,
      )!;
      expect(based.avTransport.toString(), 'http://192.168.1.15:7676/smp_19_');
      expect(
        parseDescription(
          samsungDescription.replaceFirst(
            '<controlURL>/smp_19_</controlURL>',
            '<controlURL>http://203.0.113.7/av</controlURL>',
          ),
          location,
        ),
        isNull,
      );
    });

    test('no AVTransport, or not XML: not a renderer', () {
      expect(
        parseDescription(
          samsungDescription.replaceAll('AVTransport', 'Other'),
          location,
        ),
        isNull,
      );
      expect(parseDescription('<html>nope', location), isNull);
    });
  });
}

/// Shaped like a Samsung TV's device description.
const samsungDescription = '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:sec="http://www.sec.co.kr/dlna">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>[TV]Samsung LED49</friendlyName>
    <manufacturer>Samsung Electronics</manufacturer>
    <modelName>UA49J5200</modelName>
    <modelNumber>AllShare1.0</modelNumber>
    <UDN>uuid:0ad8e2c0-0000-1000-0000-tv</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
        <controlURL>/smp_16_</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>
        <controlURL>/smp_22_</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
        <controlURL>/smp_19_</controlURL>
      </service>
    </serviceList>
  </device>
</root>''';

/// Polls that fail once with an error that isn't a [CastException].
class _Flaky implements CastSession {
  int polls = 0;

  @override
  Future<CastStatus> poll() async {
    if (polls++ == 0) throw StateError('a socket already shut');
    return const CastStatus(state: CastState.playing);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
