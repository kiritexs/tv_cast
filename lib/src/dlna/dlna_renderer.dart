import 'dart:async';
import 'dart:io';

import '../cast_device.dart';
import 'description.dart';
import 'soap.dart';
import 'ssdp.dart';

/// Finds DLNA renderers on the network: an SSDP search, then each answer's
/// device description. Each TV once, however it was reached. A description
/// read is remembered for [remember], so a TV busy playing a cast, slow to
/// serve it, isn't asked again by every search: keep one discovery for as
/// long as the app searches.
class DlnaDiscovery {
  DlnaDiscovery({
    SsdpSearcher? search,
    SoapClient? soap,
    this.describeWithin = const Duration(seconds: 4),
    this.lateBy = const Duration(seconds: 2),
    this.remember = const Duration(minutes: 5),
  }) : _search = search ?? SsdpSearch(),
       _soap = soap ?? SoapClient();

  final SsdpSearcher _search;
  final SoapClient _soap;

  /// How long one description may take, all of it.
  final Duration describeWithin;

  /// How long a search waits for descriptions once its window is over: a
  /// TV slower than that is listed by the next search.
  final Duration lateBy;

  /// How long a description read is kept.
  final Duration remember;

  /// Each description read, by the answer's location and USN.
  final _descriptions =
      <String, ({RendererDescription description, DateTime at})>{};

  /// The renderers found within [timeout], each as soon as its description
  /// is read.
  Stream<CastDevice> find({Duration timeout = const Duration(seconds: 4)}) {
    final out = StreamController<CastDevice>();
    final seen = <String>{};
    final pending = <Future<void>>[];
    StreamSubscription<SsdpAnswer>? sub;
    out.onListen = () {
      sub = _search
          .search(timeout: timeout)
          .listen(
            (answer) => pending.add(
              _describe(answer).then((renderer) {
                if (renderer == null || out.isClosed) return;
                if (seen.add(renderer.id)) out.add(renderer);
              }),
            ),
            onDone: () async {
              // One that answers later is dropped (out is closed).
              await Future.wait(
                pending,
              ).timeout(lateBy, onTimeout: () => const <void>[]);
              if (!out.isClosed) await out.close();
            },
          );
    };
    out.onCancel = () => sub?.cancel();
    return out.stream;
  }

  /// [answer]'s renderer within [describeWithin], all of it; a fetch cut
  /// off is torn down with its client.
  Future<DlnaRenderer?> _describe(SsdpAnswer answer) async {
    final client = HttpClient()..connectionTimeout = describeWithin;
    try {
      return await _renderer(client, answer).timeout(describeWithin);
    } on Exception {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<DlnaRenderer?> _renderer(HttpClient client, SsdpAnswer answer) async {
    final description = await _description(client, answer);
    if (description == null) return null;
    // Worked out each time: the address that reaches the TV can change.
    final via = isAnyAddress(answer.via)
        ? await addressTowards(answer.location.host, answer.location.port)
        : answer.via;
    return via == null
        ? null
        : DlnaRenderer(description, localAddress: via, soap: _soap);
  }

  /// The description remembered, else read. Only one read here, with no
  /// redirect followed, is kept; its key holds the USN (the TV's uuid), so
  /// another device given the same address isn't taken for it.
  Future<RendererDescription?> _description(
    HttpClient client,
    SsdpAnswer answer,
  ) async {
    final key = '${answer.location}|${answer.usn}';
    final now = DateTime.now();
    _descriptions.removeWhere((_, d) => now.difference(d.at) > remember);
    final known = _descriptions[key];
    if (known != null) return known.description;

    final req = await client.getUrl(answer.location);
    // Where the answer named, and nowhere else: a redirect could reach
    // this device's services or the internet.
    req.followRedirects = false;
    final res = await req.close();
    if (res.statusCode != 200) return null;
    final text = await res.transform(lenientUtf8).join();
    final description = parseDescription(text, answer.location);
    if (description != null) {
      _descriptions[key] = (description: description, at: DateTime.now());
    }
    return description;
  }
}

/// A DLNA media renderer (a smart TV).
class DlnaRenderer implements CastDevice {
  DlnaRenderer(this.description, {required this.localAddress, SoapClient? soap})
    : _soap = soap ?? SoapClient();

  final RendererDescription description;
  final SoapClient _soap;

  @override
  final InternetAddress localAddress;

  @override
  String get id => description.udn;

  @override
  String get name => description.name;

  @override
  String get maker => description.maker;

  @override
  String get model => description.model;

  @override
  CastProtocol get protocol => CastProtocol.dlna;

  @override
  Future<CastSession> connect() async => DlnaSession(this, _soap);
}

/// Control of a DLNA renderer through its AVTransport service.
class DlnaSession implements CastSession {
  DlnaSession(this._renderer, this._soap);

  final DlnaRenderer _renderer;
  final SoapClient _soap;
  bool _closed = false;

  @override
  CastDevice get device => _renderer;

  Future<Map<String, String>> _av(
    String action, [
    List<(String, String)> args = const [],
  ]) => _soap.call(_renderer.description.avTransport, 'AVTransport', action, [
    ('InstanceID', '0'),
    ...args,
  ]);

  @override
  Future<void> load(Uri url, CastMedia media) async {
    // Whatever it played before goes first; a TV with nothing loaded may
    // refuse Stop, which doesn't matter.
    try {
      await _av('Stop');
    } on CastException {
      // Nothing to stop.
    }
    await _av('SetAVTransportURI', [
      ('CurrentURI', url.toString()),
      (
        'CurrentURIMetaData',
        didlLite(
          url: url,
          title: media.title,
          contentType: media.contentType,
          sizeBytes: media.sizeBytes,
        ),
      ),
    ]);
  }

  @override
  Future<void> play() => _av('Play', [('Speed', '1')]);

  @override
  Future<void> pause() => _av('Pause');

  @override
  Future<void> stop() => _av('Stop');

  @override
  Future<void> seek(Duration position) =>
      _av('Seek', [('Unit', 'REL_TIME'), ('Target', formatUpnpTime(position))]);

  /// The RenderingControl service: the TV's volume, on its master channel.
  Future<Map<String, String>> _rc(
    String action, [
    List<(String, String)> args = const [],
  ]) async {
    final url = _renderer.description.renderingControl;
    if (url == null) throw CastException(action, 'no volume control');
    return _soap.call(url, 'RenderingControl', action, [
      ('InstanceID', '0'),
      ('Channel', 'Master'),
      ...args,
    ]);
  }

  @override
  Future<CastVolume?> volume() async {
    if (_renderer.description.renderingControl == null) return null;
    final level = int.tryParse((await _rc('GetVolume'))['CurrentVolume'] ?? '');
    if (level == null) return null;
    // Mute is optional in RenderingControl: a TV without it isn't muted.
    String? mute;
    try {
      mute = (await _rc('GetMute'))['CurrentMute']?.trim();
    } on CastException catch (e) {
      if (e.busy) rethrow;
    }
    // Levels run 0 to 100 on the TVs met so far; another range would be in
    // the service's description, which isn't read.
    return CastVolume(
      level: (level / 100).clamp(0.0, 1.0),
      muted: mute == '1' || mute == 'true',
    );
  }

  @override
  Future<void> setVolume(double level) => _rc('SetVolume', [
    ('DesiredVolume', '${(level.clamp(0.0, 1.0) * 100).round()}'),
  ]);

  @override
  Future<void> setMuted(bool muted) =>
      _rc('SetMute', [('DesiredMute', muted ? '1' : '0')]);

  @override
  Future<CastStatus> poll() async {
    final transport = await _av('GetTransportInfo');
    final asked = DateTime.now();
    final position = await _av('GetPositionInfo');
    final answered = DateTime.now();
    return CastStatus(
      state: castStateOf(transport['CurrentTransportState']),
      position: parseUpnpTime(position['RelTime']) ?? Duration.zero,
      duration: parseUpnpTime(position['TrackDuration']) ?? Duration.zero,
      // Somewhere between the asking and the answer: the middle.
      sampledAt: asked.add(answered.difference(asked) ~/ 2),
    );
  }

  @override
  Stream<CastStatus> watch({Duration every = const Duration(seconds: 1)}) =>
      readingsOf(this, every, () => _closed);

  @override
  Future<void> close() async => _closed = true;
}

/// A UPnP transport state as a [CastState].
CastState castStateOf(String? transportState) =>
    switch (transportState?.trim()) {
      'PLAYING' => CastState.playing,
      'PAUSED_PLAYBACK' || 'PAUSED_RECORDING' => CastState.paused,
      'TRANSITIONING' => CastState.loading,
      'STOPPED' => CastState.stopped,
      'NO_MEDIA_PRESENT' => CastState.idle,
      _ => CastState.unknown,
    };
