import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../dlna/soap.dart' show dlnaContentFeatures;
import '../dlna/ssdp.dart' show isPrivateIPv4;
import 'byte_range.dart';

/// Where a relayed item's bytes come from.
sealed class RelaySource {
  const RelaySource({this.contentType = 'video/mp4'});

  /// What the TV is told it gets, whatever the host says.
  final String contentType;
}

/// A file on this device.
final class FileSource extends RelaySource {
  const FileSource(this.path, {super.contentType});

  final String path;
}

/// A link a stream comes from, and the headers its host needs.
typedef UpstreamLink = ({Uri url, Map<String, String> headers});

/// A stream from another host, fetched with [link]'s headers, which never
/// reach the TV.
final class UpstreamSource extends RelaySource {
  const UpstreamSource(this.link, {this.refresh, super.contentType});

  final UpstreamLink link;

  /// A fresh link when this one has expired (401, 403, 410, or a page in
  /// place of the video); null when none can be had.
  final Future<UpstreamLink?> Function()? refresh;
}

/// One request the relay answered, for the diagnostics log. It never holds
/// the item's token or the upstream link.
class RelayEvent {
  const RelayEvent({
    required this.method,
    required this.status,
    required this.client,
    this.range,
    this.bytes = 0,
    this.upstreamMs,
    this.ms,
    this.note,
  });

  final String method;
  final String? range;
  final int status;
  final String client;
  final int bytes;

  /// How long the upstream took to answer, for a stream.
  final int? upstreamMs;

  /// How long the whole answer took, from the request to its last byte.
  final int? ms;
  final String? note;

  /// What the TV read per second, in MB; null for a short or quick answer.
  double? get megabytesPerSecond {
    final took = ms;
    if (took == null || took < 200 || bytes < 256 * 1024) return null;
    return bytes / took / 1000;
  }

  @override
  String toString() {
    final rate = megabytesPerSecond;
    return 'RelayEvent($method ${range ?? 'whole'} -> $status, $bytes bytes'
        '${ms == null ? '' : ' in $ms ms'}'
        '${rate == null ? '' : ' (${rate.toStringAsFixed(2)} MB/s)'}'
        '${upstreamMs == null ? '' : ', upstream $upstreamMs ms'}'
        '${note == null ? '' : ', $note'} from $client)';
  }
}

/// Serves videos to TVs on the local network: one unguessable URL per item,
/// ranges, the headers DLNA TVs ask for. A stream's bytes are fetched
/// upstream with its own headers as the TV asks for them, so its cookie and
/// user agent stay on this device.
class MediaRelay {
  MediaRelay._(this._server, this._limits) {
    _server.autoCompress = false;
    _server.listen(_handle);
  }

  /// A relay on [address] (this device's address the TV reaches), on
  /// [port] or any free one. A stream's host has [upstreamWithin] to answer
  /// and may then go quiet for [upstreamIdle] at most; after a link no
  /// refresh could replace, the item answers 502 at once for
  /// [refreshPause] before it refreshes again.
  static Future<MediaRelay> start(
    InternetAddress address, {
    int port = 0,
    Duration upstreamWithin = const Duration(seconds: 20),
    Duration upstreamIdle = const Duration(seconds: 30),
    Duration refreshPause = const Duration(seconds: 30),
  }) async => MediaRelay._(await HttpServer.bind(address, port), (
    within: upstreamWithin,
    idle: upstreamIdle,
    pause: refreshPause,
  ));

  final HttpServer _server;
  final _Limits _limits;
  final _items = <String, _Item>{};
  final _events = StreamController<RelayEvent>.broadcast();
  final _random = Random.secure();

  InternetAddress get address => _server.address;
  int get port => _server.port;

  /// Every request answered.
  Stream<RelayEvent> get events => _events.stream;

  /// Serves [source]; the URL the TV is given.
  Uri add(RelaySource source, {String name = 'video.mp4'}) {
    final token = List.generate(
      16,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    _items[token] = _Item(source, _limits);
    return Uri(
      scheme: 'http',
      host: _server.address.address,
      port: _server.port,
      pathSegments: [token, name],
    );
  }

  /// Stops serving the item at [url], and ends its fetches upstream.
  void remove(Uri url) {
    if (url.pathSegments.isNotEmpty) {
      _items.remove(url.pathSegments.first)?.close();
    }
  }

  Future<void>? _closing;

  /// Stops serving every item and ends their fetches upstream. Closing
  /// again, also while it closes, waits for the same close.
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    for (final item in _items.values) {
      item.close();
    }
    _items.clear();
    await _server.close(force: true);
    await _events.close();
  }

  void _event(RelayEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  Future<void> _handle(HttpRequest req) async {
    final began = DateTime.now();
    final res = req.response;
    final client = req.connectionInfo?.remoteAddress;
    final from = client?.address ?? '?';
    final range = req.headers.value(HttpHeaders.rangeHeader);
    Future<void> refuse(int status, String note) async {
      res.statusCode = status;
      await res.close();
      _event(
        RelayEvent(
          method: req.method,
          range: range,
          status: status,
          client: from,
          note: note,
        ),
      );
    }

    if (client == null ||
        !(client.isLoopback || client.isLinkLocal || isPrivateIPv4(client))) {
      return refuse(HttpStatus.forbidden, 'not on the local network');
    }
    final segments = req.uri.pathSegments;
    final item = segments.length == 2 ? _items[segments.first] : null;
    if (item == null) return refuse(HttpStatus.notFound, 'no such item');
    if (req.method != 'GET' && req.method != 'HEAD') {
      return refuse(HttpStatus.methodNotAllowed, req.method);
    }

    final source = item.source;
    res.headers
      ..set(HttpHeaders.contentTypeHeader, source.contentType)
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set('transferMode.dlna.org', 'Streaming')
      ..set('Access-Control-Allow-Origin', '*');
    if (req.headers.value('getcontentfeatures.dlna.org') != null) {
      res.headers.set('contentFeatures.dlna.org', dlnaContentFeatures);
    }

    try {
      switch (source) {
        case FileSource():
          await _serveFile(req, item, source, from, began);
        case UpstreamSource():
          await _serveUpstream(req, item, source, from, began);
      }
    } on RangeNotSatisfiable {
      res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */${item.size}');
      await refuse(HttpStatus.requestedRangeNotSatisfiable, 'past the end');
    } on _UpstreamFailed catch (e) {
      await refuse(HttpStatus.badGateway, e.note);
    } on Exception catch (e) {
      // Nothing promised yet (only _setLength sets the length): an answer
      // that never got going is a 502, never an empty 200.
      if (res.contentLength < 0) {
        return refuse(HttpStatus.badGateway, 'failed: ${e.runtimeType}');
      }
      // The TV went away mid-answer (a seek), the host went quiet, or the
      // file vanished.
      _event(
        RelayEvent(
          method: req.method,
          range: range,
          status: res.statusCode,
          client: from,
          note: 'ended: ${e.runtimeType}',
        ),
      );
      try {
        await res.close();
      } on Exception {
        // Already gone.
      }
    }
  }

  Future<void> _serveFile(
    HttpRequest req,
    _Item item,
    FileSource source,
    String from,
    DateTime began,
  ) async {
    final res = req.response;
    final file = File(source.path);
    if (!await file.exists()) throw const _UpstreamFailed('no file');
    final size = item.size = await file.length();
    final range = parseRange(req.headers.value(HttpHeaders.rangeHeader), size);
    _setLength(res, range, size);
    var sent = 0;
    if (req.method == 'GET') {
      final start = range?.start ?? 0;
      final end = range?.end ?? size - 1;
      await res.addStream(
        file.openRead(start, end + 1).map((chunk) {
          sent += chunk.length;
          return chunk;
        }),
      );
    }
    await res.close();
    _event(
      RelayEvent(
        method: req.method,
        range: req.headers.value(HttpHeaders.rangeHeader),
        status: res.statusCode,
        client: from,
        bytes: sent,
        ms: DateTime.now().difference(began).inMilliseconds,
      ),
    );
  }

  Future<void> _serveUpstream(
    HttpRequest req,
    _Item item,
    UpstreamSource source,
    String from,
    DateTime began,
  ) async {
    final res = req.response;
    final asked = req.headers.value(HttpHeaders.rangeHeader);
    final size = await item.knownSize(source);
    final range = parseRange(asked, size);
    if (req.method == 'HEAD') {
      _setLength(res, range, size);
      await res.close();
      _event(RelayEvent(method: 'HEAD', status: res.statusCode, client: from));
      return;
    }

    final started = DateTime.now();
    // Before the length goes on the answer: a fetch that fails then is
    // still a 502, not an answer that promised bytes.
    final upstream = await item.fetch(source, range);
    final upstreamMs = DateTime.now().difference(started).inMilliseconds;
    _setLength(res, range, size);
    var sent = 0;
    try {
      await res.addStream(
        upstream.body.map((chunk) {
          sent += chunk.length;
          return chunk;
        }),
      );
      await res.close();
    } finally {
      upstream.close();
    }
    _event(
      RelayEvent(
        method: 'GET',
        range: asked,
        status: res.statusCode,
        client: from,
        bytes: sent,
        upstreamMs: upstreamMs,
        ms: DateTime.now().difference(began).inMilliseconds,
      ),
    );
  }

  /// `200` with the whole length, or `206` with the range's.
  static void _setLength(HttpResponse res, ByteRange? range, int size) {
    if (range == null) {
      res.statusCode = HttpStatus.ok;
      res.contentLength = size;
    } else {
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(HttpHeaders.contentRangeHeader, range.contentRange);
      res.contentLength = range.length;
    }
  }
}

class _UpstreamFailed implements Exception {
  const _UpstreamFailed(this.note);

  final String note;
}

/// A body coming from upstream, and how to stop it.
typedef _Upstream = ({Stream<List<int>> body, void Function() close});

/// How long a host may take, and how long a link no refresh replaced
/// rests.
typedef _Limits = ({Duration within, Duration idle, Duration pause});

/// One relayed item: its source, the link in use and the size it learned.
/// The requests a TV makes for it at once share one probe and one refresh.
class _Item {
  _Item(this.source, this._limits)
    : _link = switch (source) {
        UpstreamSource(:final link) => link,
        FileSource() => null,
      };

  final RelaySource source;
  final _Limits _limits;
  UpstreamLink? _link;
  int? size;

  /// The probe running, which every request waiting for the size shares.
  Future<int>? _probing;

  /// The refresh running, which every request the link failed shares.
  Future<UpstreamLink?>? _refreshing;

  /// A link no refresh could replace: answered 502 at once, without asking
  /// its host or the app's resolver, until [_restsUntil].
  UpstreamLink? _resting;
  DateTime _restsUntil = DateTime(0);

  /// The fetches upstream still open, ended when the item is removed.
  final _clients = <HttpClient>{};
  bool _closed = false;

  /// The stream's size: known, or learned once however many ask.
  Future<int> knownSize(UpstreamSource source) {
    final known = size;
    if (known != null) return Future.value(known);
    return _probing ??= _probe(source).whenComplete(() => _probing = null);
  }

  /// Ends every fetch still open; none starts after.
  void close() {
    _closed = true;
    for (final client in _clients) {
      client.close(force: true);
    }
    _clients.clear();
  }

  /// Learns the stream's size from a one-byte request. A host that won't
  /// say it can't be relayed: a TV needs the length to seek.
  Future<int> _probe(UpstreamSource source) async {
    final answer = await fetch(source, null, probe: true);
    answer.close();
    final known = size;
    if (known == null) throw const _UpstreamFailed('no length upstream');
    return known;
  }

  bool _rests(UpstreamLink link) =>
      identical(link, _resting) && DateTime.now().isBefore(_restsUntil);

  void _rest(UpstreamLink link) {
    _resting = link;
    _restsUntil = DateTime.now().add(_limits.pause);
  }

  /// [range] of the stream from upstream (all of it when null), trying a
  /// fresh link once when the one in use has expired.
  Future<_Upstream> fetch(
    UpstreamSource source,
    ByteRange? range, {
    bool probe = false,
  }) async {
    for (var attempt = 0; ; attempt++) {
      final link = _link!;
      if (_rests(link)) throw const _UpstreamFailed('link expired');
      if (_closed) throw const _UpstreamFailed('removed');
      // One client per request, on purpose: no pooled connection the CDN
      // may have dropped.
      final client = HttpClient()
        ..autoUncompress = false
        ..connectionTimeout = const Duration(seconds: 15);
      _clients.add(client);
      void done() {
        _clients.remove(client);
        client.close(force: true);
      }

      HttpClientResponse response;
      try {
        final req = await client.getUrl(link.url);
        link.headers.forEach((k, v) {
          if (k.toLowerCase() != 'accept-encoding') req.headers.set(k, v);
        });
        req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        if (probe) {
          req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
        } else if (range != null) {
          req.headers.set(
            HttpHeaders.rangeHeader,
            'bytes=${range.start}-${range.end}',
          );
        }
        // A host that never answers lets go of the TV.
        response = await req.close().timeout(_limits.within);
      } on TimeoutException {
        done();
        throw const _UpstreamFailed('upstream timed out');
      } catch (_) {
        done();
        throw _UpstreamFailed(_closed ? 'removed' : 'upstream unreachable');
      }

      final expired =
          response.statusCode == HttpStatus.unauthorized ||
          response.statusCode == HttpStatus.forbidden ||
          response.statusCode == HttpStatus.gone ||
          (response.headers.contentType?.mimeType == 'text/html');
      if (expired) {
        done();
        if (attempt > 0) {
          // The fresh link is refused too: the resolver rests a while.
          _rest(link);
          throw const _UpstreamFailed('link expired');
        }
        if (await _fresh(source, link) == null) {
          throw const _UpstreamFailed('link expired');
        }
        continue;
      }
      final status = response.statusCode;
      if (status != HttpStatus.ok && status != HttpStatus.partialContent) {
        done();
        throw _UpstreamFailed('upstream $status');
      }

      final total = _totalOf(response);
      if (total != null) size = total;
      if (probe) return (body: const Stream<List<int>>.empty(), close: done);
      // A host that ignored the range sends it all: cut out what was asked.
      // The quiet limit is on what the host sends, so skipping a prefix
      // can't trip it, and it stops while the TV doesn't read.
      final skip = status == HttpStatus.ok ? range?.start ?? 0 : 0;
      final take = range?.length;
      return (
        body: _slice(response.timeout(_limits.idle), skip, take),
        close: done,
      );
    }
  }

  /// A link in place of [refused]: the one another request already put in,
  /// or the one refresh that every request [refused] failed waits for.
  /// Null, and the link rests, when there is none.
  Future<UpstreamLink?> _fresh(UpstreamSource source, UpstreamLink refused) {
    if (!identical(_link, refused)) return Future.value(_link);
    if (_rests(refused)) return Future.value();
    return _refreshing ??= _refresh(
      source,
      refused,
    ).whenComplete(() => _refreshing = null);
  }

  /// Asks the app for a fresh link. Whatever its resolver throws (offline,
  /// a bad link) is a 502 that says so, never with a URL or a token.
  Future<UpstreamLink?> _refresh(
    UpstreamSource source,
    UpstreamLink refused,
  ) async {
    final UpstreamLink? fresh;
    try {
      fresh = await source.refresh?.call();
    } on Object catch (e) {
      _rest(refused);
      throw _UpstreamFailed('no fresh link: ${e.runtimeType}');
    }
    if (fresh == null) {
      _rest(refused);
      return null;
    }
    // Only while the refused link is still in use: never over a newer one.
    if (identical(_link, refused)) _link = fresh;
    return _link;
  }

  static int? _totalOf(HttpClientResponse response) {
    final contentRange = response.headers.value(HttpHeaders.contentRangeHeader);
    if (contentRange != null) {
      return int.tryParse(contentRange.split('/').last.trim());
    }
    return response.statusCode == HttpStatus.ok && response.contentLength >= 0
        ? response.contentLength
        : null;
  }

  /// [source] without its first [skip] bytes, and at most [take] after.
  static Stream<List<int>> _slice(
    Stream<List<int>> source,
    int skip,
    int? take,
  ) async* {
    var toSkip = skip;
    var left = take;
    await for (var chunk in source) {
      if (toSkip > 0) {
        if (chunk.length <= toSkip) {
          toSkip -= chunk.length;
          continue;
        }
        chunk = chunk.sublist(toSkip);
        toSkip = 0;
      }
      if (left != null) {
        if (left <= 0) return;
        if (chunk.length > left) chunk = chunk.sublist(0, left);
        left -= chunk.length;
      }
      yield chunk;
    }
  }
}
