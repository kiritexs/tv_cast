import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../cast_device.dart';
import '../dlna/ssdp.dart' show addressTowards, isAnyAddress;
import 'cast_message.dart';
import 'mdns.dart';

/// Finds Google Cast devices (Chromecast, Google TV, TVs with Chromecast
/// built in) with mDNS. Each device once.
class GoogleCastDiscovery {
  GoogleCastDiscovery({MdnsSearch? search, CastSocketOpener? open})
    : _search = search ?? MdnsSearch(),
      _open = open;

  final MdnsSearch _search;
  final CastSocketOpener? _open;

  Stream<CastDevice> find({Duration timeout = const Duration(seconds: 4)}) =>
      _search.search(timeout: timeout).asyncExpand((answer) async* {
        // Found from any address: the one that reaches it serves it.
        if (isAnyAddress(answer.via)) {
          final via = await addressTowards(answer.address.address, answer.port);
          if (via == null) return;
          answer = MdnsAnswer(
            instance: answer.instance,
            address: answer.address,
            port: answer.port,
            txt: answer.txt,
            via: via,
          );
        }
        yield GoogleCastDevice.fromAnswer(answer, open: _open);
      });
}

/// Opens the channel's socket: TLS on the device's port, by default.
typedef CastSocketOpener =
    Future<Socket> Function(InternetAddress host, int port);

/// A Google Cast device. Its certificate is the device's own, signed by
/// Google's device authority, which only the Cast SDK checks; on the local
/// network the channel takes it as it is, as every client outside the SDK
/// does.
class GoogleCastDevice implements CastDevice {
  GoogleCastDevice({
    required this.id,
    required this.name,
    required this.model,
    required this.address,
    required this.port,
    required this.localAddress,
    CastSocketOpener? open,
    this.heartbeatEvery = const Duration(seconds: 5),
  }) : _open = open ?? _tls;

  factory GoogleCastDevice.fromAnswer(
    MdnsAnswer answer, {
    CastSocketOpener? open,
  }) => GoogleCastDevice(
    id: answer.txt['id'] ?? answer.instance,
    name: answer.txt['fn'] ?? answer.instance.split('.').first,
    model: answer.txt['md'] ?? '',
    address: answer.address,
    port: answer.port,
    localAddress: answer.via,
    open: open,
  );

  static Future<Socket> _tls(InternetAddress host, int port) =>
      SecureSocket.connect(
        host,
        port,
        onBadCertificate: (_) => true,
        timeout: const Duration(seconds: 5),
      );

  @override
  final String id;
  @override
  final String name;
  @override
  final String model;
  final InternetAddress address;
  final int port;
  @override
  final InternetAddress localAddress;
  final CastSocketOpener _open;

  /// How often its channels ask whether the device is still there.
  final Duration heartbeatEvery;

  @override
  String get maker => 'Google';

  @override
  CastProtocol get protocol => CastProtocol.googleCast;

  @override
  Future<CastSession> connect() async =>
      GoogleCastSession(this, await _channel(), reconnect: _channel)..start();

  Future<CastChannel> _channel() async {
    try {
      return CastChannel(
        await _open(address, port),
        heartbeatEvery: heartbeatEvery,
      );
    } on Exception catch (e) {
      throw CastException('connect', '$e');
    }
  }
}

/// The namespaces a sender speaks.
abstract final class CastNamespace {
  static const connection = 'urn:x-cast:com.google.cast.tp.connection';
  static const heartbeat = 'urn:x-cast:com.google.cast.tp.heartbeat';
  static const receiver = 'urn:x-cast:com.google.cast.receiver';
  static const media = 'urn:x-cast:com.google.cast.media';
}

/// One connection to a device: messages in and out, requests answered by
/// their `requestId`, and the heartbeat that keeps it open. A device that
/// says nothing for [quietTicksBeforeLost] heartbeats in a row is gone:
/// the channel closes, and the next command connects again. Ticks, not
/// the clock, so a process the system froze
/// (doze, a suspended laptop) isn't taken for a dead device on waking.
class CastChannel {
  CastChannel(
    this._socket, {
    this.heartbeatEvery = const Duration(seconds: 5),
  }) {
    // A write that fails later (the TV reset the connection) is reported
    // on `done` alone: heard here, so it closes the channel instead of
    // reaching the zone as an uncaught error.
    unawaited(_socket.done.then<void>((_) {}, onError: (Object _) => close()));
  }

  static const sender = 'sender-0';
  static const receiver = 'receiver-0';
  static const quietTicksBeforeLost = 3;

  final Socket _socket;
  final Duration heartbeatEvery;

  /// Anything heard since the last heartbeat, and heartbeats in a row with
  /// nothing.
  bool _heard = true;
  int _quietTicks = 0;
  final _reader = CastFrameReader();
  final _waiting = <int, Completer<Map<String, Object?>>>{};
  final _messages = StreamController<CastMessage>.broadcast();
  StreamSubscription<List<int>>? _sub;
  Timer? _heartbeat;
  int _nextId = 1;
  bool _closed = false;

  /// Every message the device sends.
  Stream<CastMessage> get messages => _messages.stream;
  bool get closed => _closed;

  void open() {
    _sub = _socket.listen(
      (chunk) {
        _heard = true;
        final List<CastMessage> got;
        try {
          got = _reader.add(chunk);
        } on Object {
          // A broken frame, or a reader bug: the channel closes, never
          // half-open. The next command connects again.
          unawaited(close());
          return;
        }
        got.forEach(_onMessage);
      },
      onError: (Object _) => unawaited(close()),
      onDone: () => unawaited(close()),
    );
    send(CastNamespace.connection, {'type': 'CONNECT'});
    _heartbeat = Timer.periodic(heartbeatEvery, (_) => _beat());
  }

  void _beat() {
    if (_heard) {
      _quietTicks = 0;
    } else if (++_quietTicks >= quietTicksBeforeLost) {
      unawaited(close());
      return;
    }
    _heard = false;
    send(CastNamespace.heartbeat, {'type': 'PING'});
  }

  void _onMessage(CastMessage message) {
    final json = message.json;
    if (message.namespace == CastNamespace.heartbeat &&
        json['type'] == 'PING') {
      send(CastNamespace.heartbeat, {
        'type': 'PONG',
      }, destination: message.source);
      return;
    }
    final id = json['requestId'];
    if (id is int && id != 0) _waiting.remove(id)?.complete(json);
    if (!_messages.isClosed) _messages.add(message);
  }

  void send(
    String namespace,
    Map<String, Object?> payload, {
    String destination = receiver,
  }) {
    if (_closed) return;
    try {
      _socket.add(
        CastMessage(
          source: sender,
          destination: destination,
          namespace: namespace,
          payload: jsonEncode(payload),
        ).frame(),
      );
    } on Object {
      // A socket already shut (an exception or a StateError): closed.
      unawaited(close());
    }
  }

  /// Sends [payload] with a new `requestId` and waits for the answer that
  /// carries it.
  Future<Map<String, Object?>> request(
    String action,
    String namespace,
    Map<String, Object?> payload, {
    String destination = receiver,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (_closed) throw CastException(action, 'the connection is closed');
    final id = _nextId++;
    final answer = Completer<Map<String, Object?>>();
    _waiting[id] = answer;
    send(namespace, {...payload, 'requestId': id}, destination: destination);
    try {
      return await answer.future.timeout(timeout);
    } on TimeoutException {
      throw CastException(action, 'no answer');
    } finally {
      _waiting.remove(id);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _heartbeat?.cancel();
    for (final waiting in _waiting.values) {
      if (!waiting.isCompleted) {
        waiting.completeError(const CastException('request', 'closed'));
      }
    }
    _waiting.clear();
    await _sub?.cancel();
    // What was queued last (a CLOSE, so the TV forgets this sender) gets a
    // moment to leave before the socket goes; a dead one doesn't hold it.
    try {
      await _socket.flush().timeout(const Duration(milliseconds: 300));
    } on Object {
      // Gone already.
    }
    _socket.destroy();
    await _messages.close();
  }
}

/// Control of one Google Cast device through the Default Media Receiver,
/// which plays a URL with no receiver app of ours on the device.
class GoogleCastSession implements CastSession {
  GoogleCastSession(
    this.device,
    this._channel, {
    Future<CastChannel> Function()? reconnect,
  }) : _reconnect = reconnect;

  /// Google's Default Media Receiver.
  static const defaultReceiver = 'CC1AD845';

  @override
  final CastDevice device;
  CastChannel _channel;
  final Future<CastChannel> Function()? _reconnect;
  Future<CastChannel>? _reconnecting;
  StreamSubscription<CastMessage>? _heard;
  String? _transport;
  String? _appSession;
  int? _mediaSession;
  Duration _duration = Duration.zero;
  bool _closed = false;

  void start() {
    unawaited(_heard?.cancel());
    _heard = _channel.messages.listen(_onMessage);
    _channel.open();
  }

  /// The device saying the receiver app is gone (its Home, or the Default
  /// Media Receiver idling out), or another session took it: the next
  /// reading says stopped, and only a Load launches it again. Otherwise
  /// commands would go to the dead app and time out.
  void _onMessage(CastMessage message) {
    final json = message.json;
    final gone = switch (json['type']) {
      'CLOSE' =>
        message.namespace == CastNamespace.connection &&
            message.source == _transport,
      'RECEIVER_STATUS' =>
        _transport != null && _receiverApp(json)?.session != _appSession,
      _ => false,
    };
    if (gone) _forgetApp();
  }

  void _forgetApp() {
    _mediaSession = null;
    _transport = null;
    _appSession = null;
  }

  /// The connection, opened again when it dropped (the Wi-Fi, the device
  /// asleep a moment): one try, then the command fails as before.
  Future<CastChannel> _live() async {
    final reconnect = _reconnect;
    if (!_channel.closed || _closed || reconnect == null) return _channel;
    return _reconnecting ??= () async {
      try {
        final channel = await reconnect();
        // Closed while it connected: nothing may keep it open.
        if (_closed) {
          await channel.close();
          throw const CastException('connect', 'the session closed');
        }
        _channel = channel;
        // Only the connection to the app went with the old socket: the app
        // and its media session still run on the TV, so Pause, Seek and
        // Stop keep working; `_app` joins it again, and forgets them if
        // another app session took its place.
        _transport = null;
        start();
        return _channel;
      } finally {
        _reconnecting = null;
      }
    }();
  }

  /// The receiver app running, and connected to, with the connection that
  /// reached it: a command uses the two together, so a reconnect between
  /// them can't send it to an app that connection never joined. Only
  /// [launch] (Load) starts the app; null when none runs (closed on the
  /// TV), so a reading never opens it again.
  Future<({CastChannel channel, String transport})?> _app({
    bool launch = false,
  }) async {
    final channel = await _live();
    final known = _transport;
    if (known != null) return (channel: channel, transport: known);
    var status = await channel.request('status', CastNamespace.receiver, {
      'type': 'GET_STATUS',
    });
    var app = _receiverApp(status);
    if (app == null) {
      // Closed on the TV: nothing of it is left to control.
      _forgetApp();
      if (!launch) return null;
      status = await channel.request('launch', CastNamespace.receiver, {
        'type': 'LAUNCH',
        'appId': defaultReceiver,
      }, timeout: const Duration(seconds: 20));
      app = _receiverApp(status);
    }
    if (app == null) throw const CastException('launch', 'did not start');
    // Another session of the app (started anew): its media is not ours.
    if (app.session != _appSession) _mediaSession = null;
    _appSession = app.session;
    channel.send(CastNamespace.connection, {
      'type': 'CONNECT',
    }, destination: app.transport);
    _transport = app.transport;
    return (channel: channel, transport: app.transport);
  }

  static ({String transport, String session})? _receiverApp(
    Map<String, Object?> status,
  ) {
    final apps = (status['status'] as Map?)?['applications'];
    if (apps is! List) return null;
    for (final app in apps.whereType<Map>()) {
      if (app['appId'] == defaultReceiver &&
          app['transportId'] is String &&
          app['sessionId'] is String) {
        return (
          transport: app['transportId'] as String,
          session: app['sessionId'] as String,
        );
      }
    }
    return null;
  }

  Future<Map<String, Object?>> _media(
    String action,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 8),
    bool launch = false,
  }) async {
    final app = await _app(launch: launch);
    if (app == null) throw CastException(action, 'the receiver app is closed');
    final (:channel, :transport) = app;
    final answer = await channel.request(
      action,
      CastNamespace.media,
      payload,
      destination: transport,
      timeout: timeout,
    );
    final type = answer['type'];
    if (type == 'LOAD_FAILED' ||
        type == 'LOAD_CANCELLED' ||
        type == 'INVALID_REQUEST' ||
        type == 'INVALID_PLAYER_STATE') {
      throw CastException(
        action,
        '$type ${answer['reason'] ?? ''}'.trim(),
        status: 400,
        busy: type == 'INVALID_PLAYER_STATE',
      );
    }
    _read(answer);
    return answer;
  }

  /// The media session and length a MEDIA_STATUS carries.
  CastStatus? _read(Map<String, Object?> answer) {
    final list = answer['status'];
    if (list is! List || list.isEmpty || list.first is! Map) return null;
    final status = list.first as Map;
    final id = status['mediaSessionId'];
    if (id is int) _mediaSession = id;
    final length = (status['media'] as Map?)?['duration'];
    if (length is num && length > 0) _duration = _seconds(length);
    final position = status['currentTime'];
    return CastStatus(
      state: castStateOfPlayer(
        status['playerState'] as String?,
        status['idleReason'] as String?,
      ),
      position: position is num ? _seconds(position) : Duration.zero,
      duration: _duration,
    );
  }

  static Duration _seconds(num s) => Duration(milliseconds: (s * 1000).round());

  /// The media session a command goes to; read from the TV first when
  /// none is known yet (just after a reconnect, before a reading).
  Future<int> _session(String action) async {
    if (_mediaSession == null) {
      await _media(action, {'type': 'GET_STATUS'});
    }
    final id = _mediaSession;
    if (id == null) throw CastException(action, 'nothing loaded');
    return id;
  }

  @override
  Future<void> load(Uri url, CastMedia media) async {
    _mediaSession = null;
    _duration = Duration.zero;
    await _media(
      'load',
      {
        'type': 'LOAD',
        'autoplay': false,
        'currentTime': 0,
        'media': {
          'contentId': url.toString(),
          'contentType': media.contentType,
          'streamType': 'BUFFERED',
          'metadata': {'metadataType': 0, 'title': media.title},
        },
      },
      timeout: const Duration(seconds: 30),
      launch: true,
    );
  }

  @override
  Future<void> play() async => _media('play', {
    'type': 'PLAY',
    'mediaSessionId': await _session('play'),
  });

  @override
  Future<void> pause() async => _media('pause', {
    'type': 'PAUSE',
    'mediaSessionId': await _session('pause'),
  });

  @override
  Future<void> seek(Duration position) async => _media('seek', {
    'type': 'SEEK',
    'mediaSessionId': await _session('seek'),
    'currentTime': position.inMilliseconds / 1000,
  });

  /// Stops the video and the receiver app, back to the TV's own screen.
  @override
  Future<void> stop() async {
    // Joined first, so a Stop right after a reconnect still reaches the
    // app the TV is playing, rather than doing nothing.
    try {
      await _app();
    } on CastException {
      // Not reachable: the steps below fail the same way and are skipped.
    }
    final media = _mediaSession;
    if (media != null) {
      try {
        await _media('stop', {'type': 'STOP', 'mediaSessionId': media});
      } on CastException {
        // Already stopped.
      }
    }
    final session = _appSession;
    if (session != null) {
      try {
        await (await _live()).request('stop', CastNamespace.receiver, {
          'type': 'STOP',
          'sessionId': session,
        });
      } on CastException {
        // Already gone.
      }
    }
    _forgetApp();
  }

  @override
  Future<CastVolume?> volume() async {
    final status = await (await _live()).request(
      'volume',
      CastNamespace.receiver,
      {'type': 'GET_STATUS'},
    );
    final volume = (status['status'] as Map?)?['volume'];
    if (volume is! Map || volume['level'] is! num) return null;
    return CastVolume(
      level: (volume['level'] as num).toDouble().clamp(0.0, 1.0),
      muted: volume['muted'] == true,
    );
  }

  @override
  Future<void> setVolume(double level) async =>
      (await _live()).request('volume', CastNamespace.receiver, {
        'type': 'SET_VOLUME',
        'volume': {'level': level.clamp(0.0, 1.0)},
      });

  @override
  Future<void> setMuted(bool muted) async =>
      (await _live()).request('mute', CastNamespace.receiver, {
        'type': 'SET_VOLUME',
        'volume': {'muted': muted},
      });

  @override
  Future<CastStatus> poll() async {
    // Closed on the TV (its Home, or idling out): stopped there.
    if (await _app() == null) {
      return CastStatus(state: CastState.stopped, duration: _duration);
    }
    final answer = await _media('status', {'type': 'GET_STATUS'});
    return _read(answer) ??
        CastStatus(state: CastState.idle, duration: _duration);
  }

  @override
  Stream<CastStatus> watch({Duration every = const Duration(seconds: 1)}) =>
      readingsOf(this, every, () => _closed);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final transport = _transport;
    if (transport != null) {
      _channel.send(CastNamespace.connection, {
        'type': 'CLOSE',
      }, destination: transport);
    }
    _channel.send(CastNamespace.connection, {'type': 'CLOSE'});
    await _heard?.cancel();
    await _channel.close();
  }
}

/// A Cast player state as a [CastState]: idle after the end is stopped,
/// the way a DLNA TV says it.
CastState castStateOfPlayer(String? playerState, String? idleReason) =>
    switch (playerState) {
      'PLAYING' => CastState.playing,
      'PAUSED' => CastState.paused,
      'BUFFERING' || 'LOADING' => CastState.loading,
      'IDLE' when idleReason != null => CastState.stopped,
      'IDLE' => CastState.idle,
      _ => CastState.unknown,
    };
