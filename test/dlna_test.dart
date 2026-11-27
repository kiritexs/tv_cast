/// DLNA end to end against a fake TV: it answers the SSDP search, serves
/// its description, and runs the AVTransport commands with its own state.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tv_cast/src/dlna/ssdp.dart';
import 'package:tv_cast/tv_cast.dart';

import 'parsing_test.dart' show samsungDescription;

/// A renderer on loopback: SSDP on [ssdpPort], HTTP on [httpPort].
class FakeTv {
  late final RawDatagramSocket ssdp;
  late final HttpServer http;
  final actions = <String, Map<String, String>>{};
  final order = <String>[];
  String state = 'NO_MEDIA_PRESENT';
  String relTime = '0:00:00';
  String duration = '0:00:00';
  int volume = 23;
  bool muted = false;

  /// Actions answered with a UPnP fault (`701`, transition not available).
  final refusing = <String>{};

  /// Actions it doesn't have (`401`, invalid action).
  final missing = <String>{};

  /// Its readings carry a Latin-1 title, as some TVs echo one back.
  bool latin1 = false;

  /// Each action's request Content-Length; -1 when it came chunked.
  final lengths = <String, int>{};

  /// Its description answers with a redirect to where it really is.
  bool redirects = false;

  /// Its description is asked for and never sent, as a TV busy playing.
  bool stalls = false;

  /// How many times its description was asked for.
  int descriptionReads = 0;

  int get ssdpPort => ssdp.port;
  int get httpPort => http.port;

  Future<void> start() async {
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen(_http);
    ssdp = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    ssdp.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = ssdp.receive();
      if (d == null) return;
      final text = utf8.decode(d.data);
      if (!text.startsWith('M-SEARCH') || !text.contains('MediaRenderer')) {
        return;
      }
      ssdp.send(
        utf8.encode(
          'HTTP/1.1 200 OK\r\n'
          'LOCATION: http://127.0.0.1:$httpPort/smp_11_\r\n'
          'SERVER: SHP, UPnP/1.0, Samsung UPnP SDK/1.0\r\n'
          'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
          'USN: uuid:0ad8e2c0-0000-1000-0000-tv::MediaRenderer\r\n\r\n',
        ),
        d.address,
        d.port,
      );
    });
  }

  Future<void> _http(HttpRequest req) async {
    final res = req.response;
    if (req.method == 'GET' && req.uri.path == '/smp_11_') {
      descriptionReads++;
      if (stalls) return;
    }
    if (req.method == 'GET' && req.uri.path == '/smp_11_' && redirects) {
      return res.redirect(Uri.parse('/moved'));
    }
    if (req.method == 'GET' &&
        (req.uri.path == '/smp_11_' || req.uri.path == '/moved')) {
      res.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
      res.write(samsungDescription);
      return res.close();
    }
    final service = switch (req.uri.path) {
      '/smp_19_' => 'AVTransport',
      '/smp_16_' => 'RenderingControl',
      _ => null,
    };
    if (req.method != 'POST' || service == null) {
      res.statusCode = 404;
      return res.close();
    }
    final soapAction = req.headers.value('soapaction') ?? '';
    final action = soapAction.split('#').last.replaceAll('"', '');
    final body = await utf8.decoder.bind(req).join();
    final args = {
      for (final m in RegExp(r'<(\w+)>([^<]*)</\1>').allMatches(body))
        m[1]!: m[2]!,
    };
    actions[action] = args;
    lengths[action] = req.headers.contentLength;
    order.add(action);
    if (missing.contains(action)) {
      res.statusCode = 500;
      res.write(
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
        '<s:Body><s:Fault><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0">'
        '<errorCode>401</errorCode><errorDescription>Invalid Action'
        '</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>',
      );
      return res.close();
    }
    if (refusing.contains(action)) {
      res.statusCode = 500;
      res.write(
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
        '<s:Body><s:Fault><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0">'
        '<errorCode>701</errorCode><errorDescription>Transition not available'
        '</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>',
      );
      return res.close();
    }
    var out = '';
    switch (action) {
      case 'SetAVTransportURI':
        state = 'STOPPED';
        duration = '0:23:04';
      case 'Play':
        state = 'PLAYING';
      case 'Pause':
        state = 'PAUSED_PLAYBACK';
      case 'Stop':
        state = 'STOPPED';
      case 'Seek':
        relTime = args['Target']!;
      case 'GetTransportInfo':
        out =
            '<CurrentTransportState>$state</CurrentTransportState>'
            '<CurrentTransportStatus>OK</CurrentTransportStatus>';
      case 'GetPositionInfo':
        out =
            '<Track>1</Track><TrackDuration>$duration</TrackDuration>'
            '<TrackMetaData>${latin1 ? 'Pokémon' : ''}</TrackMetaData>'
            '<RelTime>$relTime</RelTime><AbsTime>NOT_IMPLEMENTED</AbsTime>';
      case 'GetVolume':
        out = '<CurrentVolume>$volume</CurrentVolume>';
      case 'SetVolume':
        volume = int.parse(args['DesiredVolume']!);
      case 'GetMute':
        out = '<CurrentMute>${muted ? 1 : 0}</CurrentMute>';
      case 'SetMute':
        muted = args['DesiredMute'] == '1';
    }
    res.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
    final reply =
        '<?xml version="1.0"?><s:Envelope '
        'xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
        '<u:${action}Response xmlns:u="urn:schemas-upnp-org:service:$service:1">'
        '$out</u:${action}Response></s:Body></s:Envelope>';
    // A "UTF-8" reply in Latin-1 bytes, é as one byte (0xE9).
    res.add(latin1 ? const Latin1Encoder().convert(reply) : utf8.encode(reply));
    await res.close();
  }

  Future<void> close() async {
    ssdp.close();
    await http.close(force: true);
  }
}

void main() {
  late FakeTv tv;
  late DlnaDiscovery discovery;

  setUp(() async {
    tv = FakeTv();
    await tv.start();
    discovery = DlnaDiscovery(
      search: SsdpSearch(
        target: InternetAddress.loopbackIPv4,
        port: tv.ssdpPort,
        localAddresses: () async => [InternetAddress.loopbackIPv4],
      ),
    );
  });

  tearDown(() => tv.close());

  Future<CastDevice> found() => discovery
      .find(timeout: const Duration(seconds: 1))
      .first
      .timeout(const Duration(seconds: 3));

  test('the search finds the TV once, with its name, model and the address '
      'it answered on', () async {
    final all = await discovery
        .find(timeout: const Duration(seconds: 1))
        .toList();
    expect(all, hasLength(1), reason: 'three searches, one TV');
    final device = all.single;
    expect(device.name, '[TV]Samsung LED49');
    expect(device.maker, 'Samsung Electronics');
    expect(device.model, 'UA49J5200 AllShare1.0');
    expect(device.protocol, CastProtocol.dlna);
    expect(device.localAddress, InternetAddress.loopbackIPv4);
  });

  // The description fetch followed redirects,
  // so an answer could send it to this device's services or the internet.
  test('a description that redirects is no TV', () async {
    tv.redirects = true;
    final all = await discovery
        .find(timeout: const Duration(seconds: 1))
        .toList();
    expect(all, isEmpty);
  });

  // Every search read each description again, and
  // waited for the slowest.
  group('descriptions', () {
    DlnaDiscovery discoveryWith({
      Duration describeWithin = const Duration(seconds: 4),
      Duration lateBy = const Duration(seconds: 2),
      Duration remember = const Duration(minutes: 5),
    }) => DlnaDiscovery(
      search: SsdpSearch(
        target: InternetAddress.loopbackIPv4,
        port: tv.ssdpPort,
        localAddresses: () async => [InternetAddress.loopbackIPv4],
      ),
      describeWithin: describeWithin,
      lateBy: lateBy,
      remember: remember,
    );

    Future<List<CastDevice>> search(DlnaDiscovery d) => d
        .find(timeout: const Duration(milliseconds: 500))
        .toList()
        .timeout(const Duration(seconds: 5));

    test('a TV that never sends its description holds the search up only '
        'a little past its window', () async {
      tv.stalls = true;
      final took = Stopwatch()..start();
      final all = await search(
        discoveryWith(
          describeWithin: const Duration(seconds: 30),
          lateBy: const Duration(milliseconds: 300),
        ),
      );
      expect(all, isEmpty);
      expect(took.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('a description that takes too long is given up', () async {
      tv.stalls = true;
      final took = Stopwatch()..start();
      final all = await search(
        discoveryWith(
          describeWithin: const Duration(milliseconds: 300),
          lateBy: const Duration(seconds: 30),
        ),
      );
      expect(all, isEmpty);
      expect(took.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('read once, then remembered by the same discovery', () async {
      final d = discoveryWith();
      expect(await search(d), hasLength(1));
      expect(await search(d), hasLength(1));
      expect(tv.descriptionReads, 1);
    });

    test('read again once remembered long enough', () async {
      final d = discoveryWith(remember: const Duration(milliseconds: 100));
      expect(await search(d), hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(await search(d), hasLength(1));
      expect(tv.descriptionReads, 2);
    });

    test('a description that redirects is never remembered', () async {
      tv.redirects = true;
      final d = discoveryWith();
      expect(await search(d), isEmpty);
      expect(await search(d), isEmpty);
      expect(tv.descriptionReads, 2);
    });
  });

  test('load, play, seek, pause, stop: the TV gets each as a real Samsung '
      'did', () async {
    final session = await (await found()).connect();
    final url = Uri.parse('http://192.168.1.17:5000/abc/episode.mp4');

    await session.load(
      url,
      const CastMedia(title: 'Ao no Hako · EP 1', sizeBytes: 247912228),
    );
    expect(tv.order, ['Stop', 'SetAVTransportURI']);
    final set = tv.actions['SetAVTransportURI']!;
    expect(set['InstanceID'], '0');
    expect(set['CurrentURI'], url.toString());
    expect(set['CurrentURIMetaData'], contains('object.item.videoItem'));
    expect(set['CurrentURIMetaData'], contains('size=&quot;247912228&quot;'));

    await session.play();
    expect(tv.actions['Play']!['Speed'], '1');
    var status = await session.poll();
    expect(status.state, CastState.playing);
    expect(status.duration, const Duration(minutes: 23, seconds: 4));

    await session.seek(const Duration(minutes: 10, seconds: 30));
    expect(tv.actions['Seek'], {
      'InstanceID': '0',
      'Unit': 'REL_TIME',
      'Target': '00:10:30',
    });
    status = await session.poll();
    expect(status.position, const Duration(minutes: 10, seconds: 30));

    await session.pause();
    expect((await session.poll()).state, CastState.paused);
    await session.stop();
    expect((await session.poll()).state, CastState.stopped);
  });

  test("a reply that isn't UTF-8 still reads, as the TV's state", () async {
    final session = await (await found()).connect();
    await session.load(
      Uri.parse('http://x/y.mp4'),
      const CastMedia(title: 't'),
    );
    await session.play();
    tv.latin1 = true;

    final status = await session.poll();
    expect(status.state, CastState.playing);
    expect(status.duration, const Duration(minutes: 23, seconds: 4));
  });

  test('a reading says about when the TV read it', () async {
    final session = await (await found()).connect();
    await session.load(
      Uri.parse('http://x/y.mp4'),
      const CastMedia(title: 't'),
    );
    final before = DateTime.now();
    final status = await session.poll();
    final after = DateTime.now();

    expect(status.sampledAt, isNotNull);
    expect(status.sampledAt!.isBefore(before), isFalse);
    expect(status.sampledAt!.isAfter(after), isFalse);
  });

  test('every command says how long it is, never chunked', () async {
    final session = await (await found()).connect();
    await session.load(
      Uri.parse('http://x/y.mp4'),
      const CastMedia(title: 't'),
    );
    await session.play();
    await session.poll();

    expect(
      tv.lengths.values,
      everyElement(greaterThan(0)),
      reason: '${tv.lengths}',
    );
  });

  test('a TV with nothing loaded may refuse Stop; loading goes on', () async {
    tv.refusing.add('Stop');
    final session = await (await found()).connect();
    await session.load(
      Uri.parse('http://x/y.mp4'),
      const CastMedia(title: 't'),
    );
    expect(tv.order, ['Stop', 'SetAVTransportURI']);
  });

  test('a refused command says which, with the TV\'s own code', () async {
    tv.refusing.add('Seek');
    final session = await (await found()).connect();
    await expectLater(
      session.seek(Duration.zero),
      throwsA(
        isA<CastException>()
            .having((e) => e.action, 'action', 'Seek')
            .having((e) => e.status, 'status', 500)
            .having((e) => e.code, 'code', 701)
            .having((e) => e.message, 'message', 'Transition not available')
            .having((e) => e.busy, 'busy', isTrue),
      ),
    );
  });

  test('the volume: read and set on the master channel, as 0 to 100', () async {
    final session = await (await found()).connect();
    expect(await session.volume(), const CastVolume(level: 0.23));

    await session.setVolume(0.456);
    expect(tv.actions['SetVolume'], {
      'InstanceID': '0',
      'Channel': 'Master',
      'DesiredVolume': '46',
    });
    await session.setMuted(true);
    expect(tv.actions['SetMute']!['DesiredMute'], '1');
    expect(await session.volume(), const CastVolume(level: 0.46, muted: true));
  });

  test('a TV without mute: its volume is still read, not muted', () async {
    tv.missing.add('GetMute');
    final session = await (await found()).connect();
    expect(await session.volume(), const CastVolume(level: 0.23));
  });

  test('watch reads the TV every interval until closed', () async {
    final session = await (await found()).connect();
    await session.play();
    final seen = <CastStatus>[];
    final sub = session
        .watch(every: const Duration(milliseconds: 30))
        .listen(seen.add);
    // Each reading is two round trips; wait for three, however long they
    // take on a busy machine.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (seen.length < 3 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await session.close();
    await sub.cancel();
    expect(seen.length, greaterThanOrEqualTo(3));
    expect(seen.every((s) => s.state == CastState.playing), isTrue);
  });

  test('a TV that went away: commands fail as unreachable, not hang', () async {
    final session = await (await found()).connect();
    await tv.close();
    await expectLater(session.play(), throwsA(isA<CastException>()));
  });
}
