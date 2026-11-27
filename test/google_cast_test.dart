/// Google Cast (`lib/src/googlecast/`): DNS and mDNS against a fake
/// responder, the CASTV2 message format, and a session against a fake
/// Chromecast that speaks the real wire format over plain TCP (the real one
/// is TLS).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tv_cast/src/googlecast/cast_message.dart';
import 'package:tv_cast/src/googlecast/dns.dart';
import 'package:tv_cast/src/googlecast/google_cast.dart';
import 'package:tv_cast/src/googlecast/mdns.dart';
import 'package:tv_cast/tv_cast.dart';

final _loopback = InternetAddress.loopbackIPv4;

/// What a Chromecast answers to `_googlecast._tcp.local`: the PTR, then its
/// SRV, TXT and A records, the later names compressed to point back.
Uint8List chromecastAnswer({
  int port = 8009,
  bool withA = true,
  List<int> a = const [192, 168, 1, 40],
}) {
  final b = BytesBuilder();
  void u16(int v) => b.add([v >> 8, v & 0xFF]);
  void name(String n) {
    for (final label in n.split('.')) {
      b
        ..addByte(utf8.encode(label).length)
        ..add(utf8.encode(label));
    }
    b.addByte(0);
  }

  void record(void Function() owner, int type, List<int> data) {
    owner();
    u16(type);
    u16(0x8001); // IN, cache flush
    b.add([0, 0, 0, 120]);
    u16(data.length);
    b.add(data);
  }

  List<int> nameBytes(String n) => [
    for (final label in n.split('.')) ...[
      utf8.encode(label).length,
      ...utf8.encode(label),
    ],
    0,
  ];

  const instance = 'Chromecast-abc._googlecast._tcp.local';
  u16(0); // id
  u16(0x8400); // a response
  u16(0);
  u16(1);
  u16(0);
  u16(withA ? 3 : 2);
  // The PTR, at offset 12; its data, the instance, starts after its 24-byte
  // name and 10 bytes of type, class, TTL and length.
  record(
    () => name('_googlecast._tcp.local'),
    DnsType.ptr,
    nameBytes(instance),
  );
  const instanceAt = 12 + 24 + 10;
  void pointer() => b.add([0xC0, instanceAt]);
  record(pointer, DnsType.srv, [
    0,
    0,
    0,
    0,
    port >> 8,
    port & 0xFF,
    ...nameBytes('abc.local'),
  ]);
  final txt = <int>[];
  for (final entry in ['id=abc123', 'md=Chromecast', 'fn=Living Room TV']) {
    txt
      ..add(utf8.encode(entry).length)
      ..addAll(utf8.encode(entry));
  }
  record(pointer, DnsType.txt, txt);
  if (withA) record(() => name('abc.local'), DnsType.a, a);
  return b.toBytes();
}

/// A Chromecast with the Default Media Receiver, as far as a sender sees.
class FakeChromecast {
  late final ServerSocket _server;
  final received = <CastMessage>[];
  final _sockets = <Socket>[];
  bool launched = false;
  double level = 0.5;
  bool muted = false;
  String playerState = 'IDLE';
  String? idleReason;
  double time = 0;
  String? loaded;

  /// Requests on the media namespace it never answers.
  bool silent = false;

  /// Answers nothing at all, PINGs included: a connection that died
  /// quietly.
  bool deaf = false;

  int get port => _server.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(_loopback, 0);
    _server.listen((socket) {
      _sockets.add(socket);
      _connections++;
      final reader = CastFrameReader();
      socket.listen((chunk) {
        for (final m in reader.add(chunk)) {
          _on(socket, m);
        }
      });
    });
  }

  Future<void> close() async {
    for (final s in _sockets) {
      s.destroy();
    }
    await _server.close();
  }

  /// The person pressed Home: the receiver app closes, says so on the
  /// connection it had, and the device's status no longer lists it.
  void closeApp() {
    launched = false;
    loaded = null;
    _reply(_sockets.last, CastNamespace.connection, 'web-5', {'type': 'CLOSE'});
    _reply(
      _sockets.last,
      CastNamespace.receiver,
      'receiver-0',
      _receiverStatus,
    );
  }

  /// The Wi-Fi blinked: every connection drops, the device stays.
  void dropConnections() {
    for (final s in _sockets) {
      s.destroy();
    }
    _sockets.clear();
  }

  int get connections => _connections;
  int _connections = 0;

  /// Sends a message of its own, as the device's PING.
  void ping() => _sockets.last.add(
    CastMessage(
      source: 'receiver-0',
      destination: 'sender-0',
      namespace: CastNamespace.heartbeat,
      payload: '{"type":"PING"}',
    ).frame(),
  );

  void _reply(Socket s, String ns, String from, Map<String, Object?> json) =>
      s.add(
        CastMessage(
          source: from,
          destination: 'sender-0',
          namespace: ns,
          payload: jsonEncode(json),
        ).frame(),
      );

  Map<String, Object?> get _receiverStatus => {
    'type': 'RECEIVER_STATUS',
    'status': {
      'volume': {'level': level, 'muted': muted},
      'applications': [
        if (launched)
          {
            'appId': GoogleCastSession.defaultReceiver,
            'transportId': 'web-5',
            'sessionId': 'session-1',
          },
      ],
    },
  };

  Map<String, Object?> get _mediaStatus => {
    'type': 'MEDIA_STATUS',
    'status': [
      if (loaded != null)
        {
          'mediaSessionId': 7,
          'playerState': playerState,
          'idleReason': ?idleReason,
          'currentTime': time,
          'media': {'duration': 1440.5},
        },
    ],
  };

  void _on(Socket s, CastMessage m) {
    received.add(m);
    if (deaf) return;
    final json = m.json;
    final id = json['requestId'];
    switch ((m.namespace, json['type'])) {
      case (CastNamespace.heartbeat, 'PING'):
        _reply(s, m.namespace, m.destination, {'type': 'PONG'});
      case (CastNamespace.receiver, 'GET_STATUS'):
        _reply(s, m.namespace, 'receiver-0', {
          ..._receiverStatus,
          'requestId': id,
        });
      case (CastNamespace.receiver, 'LAUNCH'):
        launched = true;
        _reply(s, m.namespace, 'receiver-0', {
          ..._receiverStatus,
          'requestId': id,
        });
      case (CastNamespace.receiver, 'SET_VOLUME'):
        final volume = json['volume'] as Map;
        if (volume['level'] case final num newLevel) {
          level = newLevel.toDouble();
        }
        if (volume['muted'] case final bool newMuted) muted = newMuted;
        _reply(s, m.namespace, 'receiver-0', {
          ..._receiverStatus,
          'requestId': id,
        });
      case (CastNamespace.receiver, 'STOP'):
        launched = false;
        _reply(s, m.namespace, 'receiver-0', {
          ..._receiverStatus,
          'requestId': id,
        });
      // A closed app answers nothing.
      case (CastNamespace.media, final String type) when !silent && launched:
        final url = (json['media'] as Map?)?['contentId'] as String?;
        if (type == 'LOAD' && (url ?? '').contains('bad')) {
          _reply(s, m.namespace, 'web-5', {
            'type': 'LOAD_FAILED',
            'requestId': id,
          });
          return;
        }
        switch (type) {
          case 'LOAD':
            loaded = url;
            playerState = 'PAUSED';
          case 'PLAY':
            playerState = 'PLAYING';
          case 'PAUSE':
            playerState = 'PAUSED';
          case 'SEEK':
            time = (json['currentTime'] as num).toDouble();
          case 'STOP':
            playerState = 'IDLE';
            idleReason = 'CANCELLED';
        }
        _reply(s, m.namespace, 'web-5', {..._mediaStatus, 'requestId': id});
    }
  }
}

void main() {
  group('DNS and mDNS', () {
    test('a Chromecast\'s answer: its name, model, id, address and port, '
        'compressed names followed', () {
      final answers = mdnsAnswers(
        chromecastAnswer(port: 8010),
        from: InternetAddress('192.168.1.99'),
        via: InternetAddress('192.168.1.5'),
      );
      final a = answers.single;
      expect(a.instance, 'Chromecast-abc._googlecast._tcp.local');
      expect(a.address.address, '192.168.1.40', reason: 'its A record');
      expect(a.port, 8010);
      expect(a.txt, {
        'id': 'abc123',
        'md': 'Chromecast',
        'fn': 'Living Room TV',
      });
      expect(a.via.address, '192.168.1.5');
    });

    test('no A record: the address it answered from', () {
      final a = mdnsAnswers(
        chromecastAnswer(withA: false),
        from: InternetAddress('192.168.1.99'),
        via: _loopback,
      ).single;
      expect(a.address.address, '192.168.1.99');
    });

    // SSDP's local-only rule, for mDNS too.
    test('an answer that names an address off this network, or this '
        'device from elsewhere, or port 0, is no answer', () {
      final from = InternetAddress('192.168.1.99');
      final via = InternetAddress('192.168.1.5');
      List<MdnsAnswer> read({List<int>? a, int port = 8009}) => mdnsAnswers(
        a == null ? chromecastAnswer(port: port) : chromecastAnswer(a: a),
        from: from,
        via: via,
      );
      expect(read(a: [8, 8, 8, 8]), isEmpty, reason: 'the internet');
      expect(read(a: [127, 0, 0, 1]), isEmpty, reason: 'this device');
      expect(read(a: [192, 168, 1, 5]), isEmpty, reason: "this device's own");
      expect(read(port: 0), isEmpty);
      expect(
        read(a: [169, 254, 10, 20]).single.address.address,
        '169.254.10.20',
        reason: 'link-local is on this network',
      );
      expect(
        mdnsAnswers(
          chromecastAnswer(withA: false),
          from: InternetAddress('8.8.8.8'),
          via: via,
        ),
        isEmpty,
        reason: 'no A record, from the internet',
      );
    });

    test('a broken message is no answer, not an error', () {
      final cut = chromecastAnswer().sublist(0, 30);
      expect(mdnsAnswers(cut, from: _loopback, via: _loopback), isEmpty);
    });

    test('the question asks for the Cast service\'s PTR', () {
      final q = dnsQuery(MdnsSearch.service, DnsType.ptr);
      expect(q.sublist(4, 6), [0, 1]);
      expect(utf8.decode(q.sublist(13, 24)), '_googlecast');
      expect(q.sublist(q.length - 4), [0, DnsType.ptr, 0, 1]);
    });

    test('a search: asked from an ordinary port, answered there, each '
        'device once', () async {
      final responder = await RawDatagramSocket.bind(_loopback, 0);
      final asked = <int>[];
      responder.listen((event) {
        if (event != RawSocketEvent.read) return;
        final d = responder.receive();
        if (d == null) return;
        asked.add(d.port);
        responder.send(chromecastAnswer(), d.address, d.port);
      });
      final found = await MdnsSearch(
        target: _loopback,
        port: responder.port,
        localAddresses: () async => [_loopback],
      ).search(timeout: const Duration(milliseconds: 900)).toList();
      responder.close();

      expect(found.single.txt['fn'], 'Living Room TV');
      expect(asked, isNotEmpty);
      expect(asked.first, isNot(5353));
    });
  });

  group('the message format', () {
    test('round trip, and frames split anywhere', () {
      const m = CastMessage(
        source: 'sender-0',
        destination: 'receiver-0',
        namespace: CastNamespace.receiver,
        payload: '{"type":"GET_STATUS","requestId":1}',
      );
      final bytes = [...m.frame(), ...m.frame()];
      final reader = CastFrameReader();
      final got = [
        ...reader.add(bytes.sublist(0, 3)),
        ...reader.add(bytes.sublist(3, 40)),
        ...reader.add(bytes.sublist(40)),
      ];
      expect(got, hasLength(2));
      expect(got.first.source, 'sender-0');
      expect(got.first.destination, 'receiver-0');
      expect(got.first.namespace, CastNamespace.receiver);
      expect(got.first.json['type'], 'GET_STATUS');
    });

    test('player states as TV states', () {
      expect(castStateOfPlayer('PLAYING', null), CastState.playing);
      expect(castStateOfPlayer('PAUSED', null), CastState.paused);
      expect(castStateOfPlayer('BUFFERING', null), CastState.loading);
      expect(castStateOfPlayer('IDLE', 'FINISHED'), CastState.stopped);
      expect(castStateOfPlayer('IDLE', null), CastState.idle);
      expect(castStateOfPlayer('?', null), CastState.unknown);
    });

    // A negative length sent the reader back, and
    // one 15-byte frame froze the app.
    test('a negative length is broken, not a loop', () {
      final negative = [0xF5, ...List.filled(8, 0xFF), 0x01];
      expect(
        () => CastMessage.decode(Uint8List.fromList([0x3A, ...negative])),
        throwsFormatException,
      );
      expect(
        () => CastMessage.decode(Uint8List.fromList([0x32, ...negative])),
        throwsFormatException,
        reason: 'on the payload field too, not a RangeError',
      );
    });

    test('fixed fields cut short, and a varint too long, are broken', () {
      for (final bytes in [
        [0x09, 1, 2, 3], // wire type 1 wants 8 bytes
        [0x0D, 1, 2], // wire type 5 wants 4
        [0x08, ...List.filled(11, 0x80)],
        [0x32, 0x05, 0x61],
      ]) {
        expect(
          () => CastMessage.decode(Uint8List.fromList(bytes)),
          throwsFormatException,
          reason: '$bytes',
        );
      }
    });

    test('any bytes at all: a message or a FormatException, nothing '
        'else', () {
      final random = Random(139);
      for (var i = 0; i < 5000; i++) {
        final bytes = Uint8List.fromList([
          for (var n = random.nextInt(65); n > 0; n--) random.nextInt(256),
        ]);
        try {
          CastMessage.decode(bytes);
        } on FormatException {
          // Broken, and said so.
        }
      }
    });

    test(
      'a channel sent the broken frame closes, and the app goes on',
      () async {
        final server = await ServerSocket.bind(_loopback, 0);
        server.listen(
          (peer) => peer.add([
            0, 0, 0, 11, //
            0x3A, 0xF5, ...List.filled(8, 0xFF), 0x01,
          ]),
        );
        final channel = CastChannel(
          await Socket.connect(_loopback, server.port),
        )..open();
        for (var i = 0; i < 100 && !channel.closed; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(channel.closed, isTrue);
        await server.close();
      },
    );
  });

  // The heartbeat never listened for an answer, so
  // a connection that died quietly was noticed only minutes later.
  group('the heartbeat', () {
    const beat = Duration(milliseconds: 50);

    /// A channel to a peer that reads everything and answers PINGs only
    /// when [answers].
    Future<CastChannel> channelTo({required bool answers}) async {
      final server = await ServerSocket.bind(_loopback, 0);
      addTearDown(server.close);
      server.listen((peer) {
        addTearDown(peer.destroy);
        final reader = CastFrameReader();
        peer.listen((chunk) {
          for (final m in reader.add(chunk)) {
            if (answers && m.json['type'] == 'PING') {
              peer.add(
                CastMessage(
                  source: 'receiver-0',
                  destination: m.source,
                  namespace: CastNamespace.heartbeat,
                  payload: '{"type":"PONG"}',
                ).frame(),
              );
            }
          }
        });
      });
      final channel = CastChannel(
        await Socket.connect(_loopback, server.port),
        heartbeatEvery: beat,
      )..open();
      addTearDown(channel.close);
      return channel;
    }

    test('a device that says nothing for three beats is gone', () async {
      final channel = await channelTo(answers: false);
      for (var i = 0; i < 100 && !channel.closed; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(channel.closed, isTrue);
    });

    test('a device that answers stays', () async {
      final channel = await channelTo(answers: true);
      await Future<void>.delayed(beat * 10);
      expect(channel.closed, isFalse);
    });
  });

  group('a session', () {
    late FakeChromecast cast;
    late GoogleCastDevice device;

    setUp(() async {
      cast = FakeChromecast();
      await cast.start();
      device = GoogleCastDevice(
        id: 'abc123',
        name: 'Living Room TV',
        model: 'Chromecast',
        address: _loopback,
        port: cast.port,
        localAddress: _loopback,
        open: (host, port) => Socket.connect(host, port),
      );
    });

    tearDown(() => cast.close());

    List<String> types(String namespace) => [
      for (final m in cast.received)
        if (m.namespace == namespace) m.json['type'] as String,
    ];

    test('load launches the Default Media Receiver, connects to it and '
        'loads the relay\'s URL paused; play, pause, seek and readings '
        'follow', () async {
      final session = await device.connect();
      final url = Uri.parse('http://192.168.1.5:4000/token/episode.mp4');
      await session.load(url, const CastMedia(title: 'Bleach · EP 11'));

      expect(cast.launched, isTrue);
      expect(cast.loaded, url.toString());
      final load = cast.received.firstWhere((m) => m.json['type'] == 'LOAD');
      expect(load.destination, 'web-5');
      expect(load.json['autoplay'], isFalse);
      expect(
        ((load.json['media'] as Map)['metadata'] as Map)['title'],
        'Bleach · EP 11',
      );
      expect(
        cast.received.where(
          (m) =>
              m.namespace == CastNamespace.connection &&
              m.destination == 'web-5',
        ),
        isNotEmpty,
        reason: 'connected to the app before loading',
      );

      await session.play();
      cast.time = 61.5;
      var status = await session.poll();
      expect(status.state, CastState.playing);
      expect(status.position, const Duration(milliseconds: 61500));
      expect(status.duration, const Duration(milliseconds: 1440500));

      await session.seek(const Duration(minutes: 10));
      expect(cast.time, 600);
      await session.pause();
      status = await session.poll();
      expect(status.state, CastState.paused);
      expect(types(CastNamespace.media), [
        'LOAD',
        'PLAY',
        'GET_STATUS',
        'SEEK',
        'PAUSE',
        'GET_STATUS',
      ]);
      await session.close();
    });

    test('a video the device refuses is a CastException it answered', () async {
      final session = await device.connect();
      await expectLater(
        session.load(
          Uri.parse('http://192.168.1.5:4000/t/bad.mp4'),
          const CastMedia(title: 'x'),
        ),
        throwsA(
          isA<CastException>().having((e) => e.status, 'status', isNotNull),
        ),
      );
      await session.close();
    });

    test(
      'stop ends the video and the receiver app; close says goodbye',
      () async {
        final session = await device.connect();
        await session.load(
          Uri.parse('http://x/e.mp4'),
          const CastMedia(title: ''),
        );
        await session.stop();
        expect(cast.playerState, 'IDLE');
        expect(cast.launched, isFalse);
        expect(types(CastNamespace.receiver).last, 'STOP');

        await session.close();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(types(CastNamespace.connection).last, 'CLOSE');
      },
    );

    test('the device\'s PING gets a PONG', () async {
      final session = await device.connect();
      await session.poll().catchError(
        (_) => const CastStatus(state: CastState.idle),
      );
      cast.ping();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(types(CastNamespace.heartbeat), contains('PONG'));
      await session.close();
    });

    test("the volume: the receiver's, read and set", () async {
      final session = await device.connect();
      expect(await session.volume(), const CastVolume(level: 0.5));
      await session.setVolume(0.8);
      await session.setMuted(true);
      expect(cast.level, 0.8);
      expect(await session.volume(), const CastVolume(level: 0.8, muted: true));
      await session.close();
    });

    test('nothing loaded: stopped, and a reading launches nothing', () async {
      final session = await device.connect();
      final status = await session.poll();
      expect(status.state, CastState.stopped);
      expect(types(CastNamespace.receiver), isNot(contains('LAUNCH')));
      await session.close();
    });

    // Regression: the session kept its dead app and its dropped connection,
    // so each command timed out until Stop.
    test('the TV closing the receiver app: the next load launches it '
        'again', () async {
      final session = await device.connect();
      await session.load(
        Uri.parse('http://x/1.mp4'),
        const CastMedia(title: ''),
      );
      cast.closeApp();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await session
          .load(Uri.parse('http://x/2.mp4'), const CastMedia(title: ''))
          .timeout(const Duration(seconds: 3));
      expect(cast.loaded, 'http://x/2.mp4');
      expect(
        types(CastNamespace.receiver).where((t) => t == 'LAUNCH'),
        hasLength(2),
      );
      await session.close();
    });

    // After the person closed the receiver
    // app, the next reading (every 1–3 s) launched it again on the TV.
    test('after the TV closed the receiver app, a reading says stopped and '
        'launches nothing', () async {
      final session = await device.connect();
      await session.load(
        Uri.parse('http://x/1.mp4'),
        const CastMedia(title: ''),
      );
      cast.closeApp();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final status = await session.poll().timeout(const Duration(seconds: 3));
      expect(status.state, CastState.stopped);
      expect(
        types(CastNamespace.receiver).where((t) => t == 'LAUNCH'),
        hasLength(1),
      );
      await session.close();
    });

    test('a dropped connection: the next command connects again', () async {
      final session = await device.connect();
      await session.load(
        Uri.parse('http://x/1.mp4'),
        const CastMedia(title: ''),
      );
      cast.dropConnections();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final status = await session.poll().timeout(const Duration(seconds: 3));
      expect(status.state, isNot(CastState.unknown));
      expect(cast.connections, 2);
      await session.close();
    });

    test('after a reconnect, Pause and Stop still reach the video playing, '
        'with no reading in between', () async {
      final session = await device.connect();
      await session.load(
        Uri.parse('http://x/1.mp4'),
        const CastMedia(title: ''),
      );
      await session.play();
      cast.dropConnections();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // The reconnect happens in a call that never reads the media again.
      await session.setMuted(true).timeout(const Duration(seconds: 3));
      expect(cast.connections, 2);

      await session.pause().timeout(const Duration(seconds: 3));
      expect(cast.playerState, 'PAUSED');
      await session.stop().timeout(const Duration(seconds: 3));
      expect(cast.playerState, 'IDLE');
      expect(cast.launched, isFalse, reason: 'the receiver app stopped too');
      await session.close();
    });

    test('a write the TV reset, reported on the socket\'s done alone, '
        'closes the channel: no uncaught error', () async {
      final errors = <Object>[];
      late CastChannel channel;
      await runZonedGuarded(() async {
        channel = CastChannel(_ResetSocket());
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }, (e, _) => errors.add(e));
      expect(errors, isEmpty);
      expect(channel.closed, isTrue);
    });

    test('a device gone quiet: its channel closes, and the next reading '
        'connects again', () async {
      final quick = GoogleCastDevice(
        id: 'abc123',
        name: 'Living Room TV',
        model: 'Chromecast',
        address: _loopback,
        port: cast.port,
        localAddress: _loopback,
        open: (host, port) => Socket.connect(host, port),
        heartbeatEvery: const Duration(milliseconds: 50),
      );
      final session = await quick.connect();
      await session.load(
        Uri.parse('http://x/1.mp4'),
        const CastMedia(title: ''),
      );
      cast.deaf = true;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      cast.deaf = false;

      final status = await session.poll().timeout(const Duration(seconds: 3));
      expect(status.state, isNot(CastState.unknown));
      expect(cast.connections, 2);
      await session.close();
    });

    test('a closed connection fails each command, never hangs', () async {
      final session = await device.connect();
      await session.close();
      await expectLater(session.poll(), throwsA(isA<CastException>()));
    });
  });

  test('every protocol searched at once: both searches\' devices, one '
      'failing doesn\'t end the other', () async {
    GoogleCastDevice tv(String id) => GoogleCastDevice(
      id: id,
      name: id,
      model: '',
      address: _loopback,
      port: 8009,
      localAddress: _loopback,
    );
    final found = await findCastDevices(
      searches: [
        (_) => Stream.fromIterable([tv('dlna-tv')]),
        (_) => Stream<CastDevice>.error(const SocketException('no network')),
        (_) => Stream.fromIterable([tv('chromecast')]),
      ],
    ).toList();
    expect(found.map((d) => d.id), unorderedEquals(['dlna-tv', 'chromecast']));
  });

  test('the discoveries given are the ones searched', () async {
    final dlna = _OneTv('dlna-tv');
    final googleCast = _OneChromecast();
    final found = await findCastDevices(
      dlna: dlna,
      googleCast: googleCast,
    ).toList();
    expect(found.map((d) => d.id), unorderedEquals(['dlna-tv', 'chromecast']));
    expect(dlna.searches, 1);
  });
}

/// A DLNA discovery that finds one TV, and counts its searches.
class _OneTv implements DlnaDiscovery {
  _OneTv(this.id);

  final String id;
  int searches = 0;

  @override
  Stream<CastDevice> find({Duration timeout = const Duration(seconds: 4)}) {
    searches++;
    return Stream.value(
      GoogleCastDevice(
        id: id,
        name: id,
        model: '',
        address: _loopback,
        port: 8009,
        localAddress: _loopback,
      ),
    );
  }

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _OneChromecast implements GoogleCastDiscovery {
  @override
  Stream<CastDevice> find({Duration timeout = const Duration(seconds: 4)}) =>
      Stream.value(
        GoogleCastDevice(
          id: 'chromecast',
          name: 'chromecast',
          model: '',
          address: _loopback,
          port: 8009,
          localAddress: _loopback,
        ),
      );

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A socket whose writes the peer reset: `done` fails, as dart:io reports
/// it, and nothing else is ever heard.
class _ResetSocket implements Socket {
  _ResetSocket() : done = Future.error(const SocketException('reset by peer'));

  @override
  final Future<void> done;

  @override
  Future<void> flush() async {}

  @override
  void destroy() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
