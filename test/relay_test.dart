/// The relay against a real HTTP client: a file, and a stream from a fake
/// host that wants its own headers, can expire a link and can ignore
/// ranges.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tv_cast/src/relay/byte_range.dart' show parseRange;
import 'package:tv_cast/tv_cast.dart';

/// 100 KB whose every byte says where it is.
final _bytes = List<int>.generate(100 * 1024, (i) => i % 251);

/// A host that serves [_bytes] at `/v/<name>`, only with the app's user
/// agent; `/expired` answers 403, `/page` an HTML page, `/norange` ignores
/// ranges, `/once` answers the relay's first request only and 403 after,
/// `/nolength` never says how long it is, `/stall` never answers, and
/// `/trickle` answers the probe, then sends a little of the rest and goes
/// quiet.
class FakeHost {
  late final HttpServer server;
  final requests = <({String path, String? range, String? agent})>[];

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final res = req.response;
      final range = req.headers.value(HttpHeaders.rangeHeader);
      final agent = req.headers.value(HttpHeaders.userAgentHeader);
      requests.add((path: req.uri.path, range: range, agent: agent));
      if (agent != 'relay-test-agent') {
        res.statusCode = HttpStatus.forbidden;
        return res.close();
      }
      final once = req.uri.path == '/once';
      if (req.uri.path == '/expired' ||
          (once && requests.where((q) => q.path == '/once').length > 1)) {
        res.statusCode = HttpStatus.forbidden;
        return res.close();
      }
      if (req.uri.path == '/stall') return;
      if (req.uri.path == '/trickle' && range != 'bytes=0-0') {
        res.contentLength = _bytes.length;
        res.add(_bytes.sublist(0, 1000));
        return res.flush();
      }
      if (req.uri.path == '/nolength') {
        res.add(_bytes);
        return res.close();
      }
      if (req.uri.path == '/page') {
        res.headers.contentType = ContentType.html;
        res.write('<!DOCTYPE html><html>captcha</html>');
        return res.close();
      }
      res.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/octet-stream',
      );
      final r = req.uri.path == '/norange'
          ? null
          : parseRange(range, _bytes.length);
      if (r == null) {
        res.contentLength = _bytes.length;
        res.add(_bytes);
      } else {
        res.statusCode = HttpStatus.partialContent;
        res.headers.set(HttpHeaders.contentRangeHeader, r.contentRange);
        res.contentLength = r.length;
        res.add(_bytes.sublist(r.start, r.end + 1));
      }
      await res.close();
    });
  }

  UpstreamLink link(String path) => (
    url: Uri.parse('http://127.0.0.1:${server.port}$path'),
    headers: const {'User-Agent': 'relay-test-agent', 'Cookie': 'k=v'},
  );

  Future<void> close() => server.close(force: true);
}

Future<({int status, HttpHeaders headers, List<int> body})> fetch(
  Uri url, {
  String method = 'GET',
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, url);
    headers.forEach(req.headers.set);
    final res = await req.close();
    final body = <int>[];
    await for (final chunk in res) {
      body.addAll(chunk);
    }
    return (status: res.statusCode, headers: res.headers, body: body);
  } finally {
    client.close(force: true);
  }
}

void main() {
  final events = <RelayEvent>[];

  /// The relay logs just after answering: wait for the entry.
  Future<RelayEvent> logged(bool Function(RelayEvent e) match) async {
    for (var i = 0; i < 100; i++) {
      final found = events.where(match);
      if (found.isNotEmpty) return found.last;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw StateError('not logged: $events');
  }

  late MediaRelay relay;
  late FakeHost host;
  late Directory dir;

  setUp(() async {
    relay = await MediaRelay.start(InternetAddress.loopbackIPv4);
    relay.events.listen(events.add);
    host = FakeHost();
    await host.start();
    dir = Directory.systemTemp.createTempSync('tv_cast_relay_');
    events.clear();
  });

  tearDown(() async {
    await relay.close();
    await host.close();
    dir.deleteSync(recursive: true);
  });

  group('a file', () {
    late Uri url;

    setUp(() {
      final file = File('${dir.path}/Episode_1_720p.mp4')
        ..writeAsBytesSync(_bytes);
      url = relay.add(FileSource(file.path), name: 'episode.mp4');
    });

    test('its URL is on the relay, with an unguessable token', () {
      expect(url.host, '127.0.0.1');
      expect(url.port, relay.port);
      expect(url.pathSegments.first, hasLength(32));
      expect(url.pathSegments.last, 'episode.mp4');
    });

    test('HEAD: the length, video/mp4, ranges, the DLNA headers when '
        'asked', () async {
      final r = await fetch(
        url,
        method: 'HEAD',
        headers: {'getcontentfeatures.dlna.org': '1'},
      );
      expect(r.status, 200);
      expect(r.headers.contentLength, _bytes.length);
      expect(r.headers.value('content-type'), 'video/mp4');
      expect(r.headers.value('accept-ranges'), 'bytes');
      expect(
        r.headers.value('contentfeatures.dlna.org'),
        contains('DLNA.ORG_OP=01'),
      );
      expect(r.headers.value('transfermode.dlna.org'), 'Streaming');
      expect(r.body, isEmpty);
    });

    test('the whole file, then ranges as a TV asks them', () async {
      final whole = await fetch(url);
      expect(whole.status, 200);
      expect(whole.body, _bytes);

      final from = await fetch(url, headers: {'Range': 'bytes=1000-'});
      expect(from.status, 206);
      expect(
        from.headers.value('content-range'),
        'bytes 1000-${_bytes.length - 1}/${_bytes.length}',
      );
      expect(from.body, _bytes.sublist(1000));

      final tail = await fetch(url, headers: {'Range': 'bytes=-76'});
      expect(tail.body, _bytes.sublist(_bytes.length - 76));
    });

    test('past the end: 416 with the size', () async {
      final r = await fetch(url, headers: {'Range': 'bytes=999999-'});
      expect(r.status, 416);
      expect(r.headers.value('content-range'), 'bytes */${_bytes.length}');
    });

    test('a wrong token, or a removed item: 404', () async {
      final wrong = url.replace(pathSegments: ['0' * 32, 'episode.mp4']);
      expect((await fetch(wrong)).status, 404);
      relay.remove(url);
      expect((await fetch(url)).status, 404);
    });

    test('only GET and HEAD', () async {
      expect((await fetch(url, method: 'DELETE')).status, 405);
    });
  });

  group('a stream', () {
    test('the TV\'s ranges go upstream with the host\'s headers, and come '
        'back as video/mp4', () async {
      final url = relay.add(UpstreamSource(host.link('/v/ep1')));

      final head = await fetch(url, method: 'HEAD');
      expect(head.status, 200);
      expect(head.headers.contentLength, _bytes.length);

      final r = await fetch(url, headers: {'Range': 'bytes=50000-'});
      expect(r.status, 206);
      expect(r.headers.value('content-type'), 'video/mp4');
      expect(
        r.headers.value('content-range'),
        'bytes 50000-${_bytes.length - 1}/${_bytes.length}',
      );
      expect(r.body, _bytes.sublist(50000));

      expect(host.requests.every((q) => q.agent == 'relay-test-agent'), isTrue);
      expect(host.requests.first.range, 'bytes=0-0', reason: 'the probe');
      expect(host.requests.last.range, 'bytes=50000-${_bytes.length - 1}');
      final get = await logged((e) => e.method == 'GET');
      expect(get.bytes, _bytes.length - 50000);
      expect(get.upstreamMs, isNotNull);
    });

    test('an expired link gets a fresh one once, and plays', () async {
      var asked = 0;
      final url = relay.add(
        UpstreamSource(
          host.link('/expired'),
          refresh: () async {
            asked++;
            return host.link('/v/fresh');
          },
        ),
      );
      final r = await fetch(url, headers: {'Range': 'bytes=0-99'});
      expect(r.status, 206);
      expect(r.body, _bytes.sublist(0, 100));
      expect(asked, 1);
    });

    test('a page in place of the video counts as expired; with no fresh '
        'link, 502', () async {
      final url = relay.add(UpstreamSource(host.link('/page')));
      final r = await fetch(url, headers: {'Range': 'bytes=0-'});
      expect(r.status, 502);
      expect((await logged((e) => e.status == 502)).note, 'link expired');
    });

    test(
      'a host that ignores ranges: the range is cut out of the whole',
      () async {
        final url = relay.add(UpstreamSource(host.link('/norange')));
        final r = await fetch(url, headers: {'Range': 'bytes=200-299'});
        expect(r.status, 206);
        expect(r.body, _bytes.sublist(200, 300));
      },
    );

    // Regression: the length was set before the fetch failed, so the relay
    // dropped the connection instead of answering.
    test('a link that expires after the size is known, with no fresh one: '
        '502, not a dropped connection', () async {
      final url = relay.add(UpstreamSource(host.link('/once')));
      final r = await fetch(url, headers: {'Range': 'bytes=0-'});
      expect(r.status, 502);
      expect((await logged((e) => e.status == 502)).note, 'link expired');
    });

    test('a host that never says how long it is: 502, not a wait', () async {
      final url = relay.add(UpstreamSource(host.link('/nolength')));
      final r = await fetch(url).timeout(const Duration(seconds: 5));
      expect(r.status, 502);
    });

    test('the host refusing our headers is a failure, not a video', () async {
      final url = relay.add(
        UpstreamSource((
          url: host.link('/v/x').url,
          headers: const {'User-Agent': 'TV'},
        )),
      );
      expect((await fetch(url)).status, 502);
    });

    test('the TV going away mid-answer (a seek) stops the upstream', () async {
      final url = relay.add(UpstreamSource(host.link('/v/ep1')));
      final client = HttpClient();
      final req = await client.getUrl(url);
      final res = await req.close();
      await res.first;
      client.close(force: true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // The relay is still serving the next request.
      final again = await fetch(url, headers: {'Range': 'bytes=0-9'});
      expect(again.body, _bytes.sublist(0, 10));
    });
  });

  // The requests a TV makes at
  // once share one probe and one refresh, a refresh that fails is a 502,
  // a link no refresh replaced rests, and a host that stalls lets go.
  group('a stream, its link and its host', () {
    /// A relay with short limits, logging to [events].
    Future<MediaRelay> relayWith({
      Duration upstreamWithin = const Duration(seconds: 20),
      Duration upstreamIdle = const Duration(seconds: 30),
      Duration refreshPause = const Duration(seconds: 30),
    }) async {
      final short = await MediaRelay.start(
        InternetAddress.loopbackIPv4,
        upstreamWithin: upstreamWithin,
        upstreamIdle: upstreamIdle,
        refreshPause: refreshPause,
      );
      short.events.listen(events.add);
      addTearDown(short.close);
      return short;
    }

    int asked(String path) => host.requests.where((q) => q.path == path).length;

    test('a refresh that throws (offline): 502, saying there was no fresh '
        'link', () async {
      final url = relay.add(
        UpstreamSource(
          host.link('/expired'),
          refresh: () async => throw Exception('offline'),
        ),
      );
      final r = await fetch(url, headers: {'Range': 'bytes=0-'});
      expect(r.status, 502);
      final note = (await logged((e) => e.status == 502)).note!;
      expect(note, startsWith('no fresh link'));
      expect(note, isNot(contains('127.0.0.1')), reason: 'never the link');
    });

    test('requests the same expired link failed at once refresh it once, '
        'and all play', () async {
      var refreshes = 0;
      final url = relay.add(
        UpstreamSource(
          host.link('/once'),
          refresh: () async {
            refreshes++;
            await Future<void>.delayed(const Duration(milliseconds: 100));
            return host.link('/v/fresh');
          },
        ),
      );
      // The probe learns the size from the link, which then expires.
      expect((await fetch(url, method: 'HEAD')).status, 200);

      final answers = await Future.wait([
        for (final at in [0, 1000, 2000])
          fetch(url, headers: {'Range': 'bytes=$at-${at + 99}'}),
      ]);
      expect(refreshes, 1);
      expect(asked('/once'), 4, reason: 'the probe, then each request once');
      for (final (i, at) in [0, 1000, 2000].indexed) {
        expect(answers[i].status, 206);
        expect(answers[i].body, _bytes.sublist(at, at + 100));
      }
    });

    test('requests that need the size at once share one probe', () async {
      final url = relay.add(UpstreamSource(host.link('/v/ep1')));
      final answers = await Future.wait([
        fetch(url, method: 'HEAD'),
        fetch(url, headers: {'Range': 'bytes=0-99'}),
        fetch(url, headers: {'Range': 'bytes=500-599'}),
      ]);
      expect(answers.map((a) => a.status), [200, 206, 206]);
      expect(host.requests.where((q) => q.range == 'bytes=0-0'), hasLength(1));
    });

    test('a fresh link refused too rests: 502 at once, asking neither the '
        'host nor the resolver', () async {
      var refreshes = 0;
      final short = await relayWith();
      final url = short.add(
        UpstreamSource(
          host.link('/expired'),
          refresh: () async {
            refreshes++;
            return host.link('/page');
          },
        ),
      );
      expect((await fetch(url, headers: {'Range': 'bytes=0-'})).status, 502);
      final before = host.requests.length;

      final again = await fetch(url, headers: {'Range': 'bytes=0-'});
      expect(again.status, 502);
      expect(refreshes, 1);
      expect(host.requests, hasLength(before), reason: 'no request upstream');
    });

    test('after the rest, one more refresh', () async {
      var refreshes = 0;
      final short = await relayWith(
        refreshPause: const Duration(milliseconds: 200),
      );
      final url = short.add(
        UpstreamSource(
          host.link('/expired'),
          refresh: () async {
            refreshes++;
            return host.link('/page');
          },
        ),
      );
      expect((await fetch(url, headers: {'Range': 'bytes=0-'})).status, 502);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect((await fetch(url, headers: {'Range': 'bytes=0-'})).status, 502);
      expect(refreshes, 2);
    });

    test('a link with no fresh one rests too', () async {
      var refreshes = 0;
      final url = relay.add(
        UpstreamSource(
          host.link('/expired'),
          refresh: () async {
            refreshes++;
            return null;
          },
        ),
      );
      expect((await fetch(url)).status, 502);
      expect((await fetch(url)).status, 502);
      expect(refreshes, 1);
      expect(asked('/expired'), 1);
    });

    test('a host that never answers: 502 once the wait is up', () async {
      final short = await relayWith(
        upstreamWithin: const Duration(milliseconds: 300),
      );
      final url = short.add(UpstreamSource(host.link('/stall')));
      final r = await fetch(url).timeout(const Duration(seconds: 5));
      expect(r.status, 502);
      expect((await logged((e) => e.status == 502)).note, 'upstream timed out');
    });

    test('a host that goes quiet mid-answer: the TV\'s answer ends short, '
        'and it asks again', () async {
      final short = await relayWith(
        upstreamIdle: const Duration(milliseconds: 300),
      );
      final url = short.add(UpstreamSource(host.link('/trickle')));
      var got = 0;
      try {
        final r = await fetch(url).timeout(const Duration(seconds: 5));
        got = r.body.length;
      } on HttpException {
        // The answer was cut: what a TV sees.
      }
      expect(got, lessThan(_bytes.length));
      expect(
        (await logged((e) => e.note == 'ended: TimeoutException')).method,
        'GET',
      );
    });

    test('removing an item ends its fetches upstream at once', () async {
      final url = relay.add(UpstreamSource(host.link('/stall')));
      final answer = fetch(url);
      for (var i = 0; i < 100 && asked('/stall') == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      relay.remove(url);
      final r = await answer.timeout(const Duration(seconds: 2));
      expect(r.status, 502);
      expect((await logged((e) => e.status == 502)).note, 'removed');
    });
  });

  // A relay closed by its connect and again by whoever
  // let go of it closed its server and its log twice.
  test('closing twice, also while it closes, is the same close', () async {
    relay.add(UpstreamSource(host.link('/stall')));
    final first = relay.close();
    final second = relay.close();
    expect(second, same(first));
    await Future.wait([first, second]).timeout(const Duration(seconds: 2));
    await relay.close().timeout(const Duration(seconds: 2));
  });
}
