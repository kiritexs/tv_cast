// The network between this PC and the TVs, for a slow cast: the PC's Wi-Fi
// link, the search, ping, and how fast a DLNA TV answers control requests,
// one at a time and several at once. Without a file it only reads: it never
// changes what the TV plays.
//
// With --play, it also plays [file] on the TV through the relay, twice:
// reading the TV every 2 s, then every 0.3 s. Each time it measures how long
// the TV takes to start and to seek to 5:00, how fast it answers meanwhile,
// and how fast it reads the video from this PC; then it stops the TV.
//
//   dart run example/network_check.dart [--play file.mp4]
// ignore_for_file: implementation_imports
import 'dart:async';
import 'dart:io';

import 'package:tv_cast/tv_cast.dart';

final _t0 = DateTime.now();
void say(String s) => stdout.writeln(
  '+${(DateTime.now().difference(_t0).inMilliseconds / 1000).toStringAsFixed(1)}s $s',
);

/// "min / median / p90 / max ms" of [ms].
String spread(List<int> ms) {
  if (ms.isEmpty) return 'no answers';
  final s = [...ms]..sort();
  int at(double q) => s[((s.length - 1) * q).round()];
  return 'min ${s.first} / median ${at(0.5)} / p90 ${at(0.9)} / '
      'max ${s.last} ms (${s.length} answers)';
}

const _rounds = 20;

Future<void> main(List<String> args) async {
  final play = args.indexOf('--play');
  final file = play >= 0 && play + 1 < args.length
      ? File(args[play + 1])
      : null;

  if (Platform.isWindows) {
    // The link this PC has to the router: signal, radio, channel, rates.
    // Network names and addresses are left out.
    final wlan = await Process.run('netsh', ['wlan', 'show', 'interfaces']);
    const keep = [
      'Radio type',
      'Channel',
      'Receive rate',
      'Transmit rate',
      'Signal',
      'State',
      'Band',
    ];
    say('Wi-Fi:');
    for (final line in '${wlan.stdout}'.split('\n')) {
      final name = line.split(':').first.trim();
      if (keep.any(name.startsWith)) stdout.writeln('    ${line.trim()}');
    }
  }

  say('searching for DLNA TVs…');
  final sw = Stopwatch()..start();
  final tvs = await DlnaDiscovery().find().toList();
  say('search took ${sw.elapsedMilliseconds} ms, ${tvs.length} TV(s)');
  for (final device in tvs.whereType<DlnaRenderer>()) {
    final control = device.description.avTransport;
    final host = control.host;
    say('"${device.name}" at $host (this PC: ${device.localAddress.address})');

    // Ping: the radio path, round trip and loss.
    final ping = await Process.run(
      'ping',
      Platform.isWindows ? ['-n', '$_rounds', host] : ['-c', '$_rounds', host],
    );
    for (final line in '${ping.stdout}'.split('\n')) {
      final l = line.trim();
      if (l.contains('Lost') ||
          l.contains('loss') ||
          l.contains('Average') ||
          l.contains('avg')) {
        stdout.writeln('    ping: $l');
      }
    }

    // A TCP connection to its control port: each SOAP call opens one.
    final connects = <int>[];
    for (var i = 0; i < _rounds; i++) {
      final c = Stopwatch()..start();
      try {
        final s = await Socket.connect(
          host,
          control.port,
          timeout: const Duration(seconds: 5),
        );
        connects.add(c.elapsedMilliseconds);
        s.destroy();
      } on SocketException {
        // Counted by its absence.
      }
    }
    say('connect to its control port: ${spread(connects)}');

    final soap = SoapClient();
    Future<List<int>> timed(String action, int n) async {
      final ms = <int>[];
      for (var i = 0; i < n; i++) {
        final c = Stopwatch()..start();
        try {
          await soap.call(control, 'AVTransport', action, [
            ('InstanceID', '0'),
          ]);
          ms.add(c.elapsedMilliseconds);
        } on CastException catch (e) {
          say('  $action failed: $e');
        }
      }
      return ms;
    }

    say(
      'GetTransportInfo, one at a time: '
      '${spread(await timed('GetTransportInfo', _rounds))}',
    );
    say(
      'GetPositionInfo, one at a time: '
      '${spread(await timed('GetPositionInfo', _rounds))}',
    );

    // Several at once, as a reading, a command and a volume read can be.
    final together = Stopwatch()..start();
    final parallel = await Future.wait([
      for (var i = 0; i < 4; i++) timed('GetTransportInfo', 1),
    ]);
    say(
      '4 at once: ${spread(parallel.expand((m) => m).toList())}, '
      'all done in ${together.elapsedMilliseconds} ms',
    );

    if (file != null) {
      await _playCheck(device, soap, file, const Duration(seconds: 2));
      await _playCheck(device, soap, file, const Duration(milliseconds: 300));
    }
  }
}

/// Plays [file] on [device], reading it every [every]; see the header.
Future<void> _playCheck(
  DlnaRenderer device,
  SoapClient soap,
  File file,
  Duration every,
) async {
  final control = device.description.avTransport;
  say('— playing, reading the TV every ${every.inMilliseconds} ms —');
  final relay = await MediaRelay.start(device.localAddress);
  final events = <RelayEvent>[];
  final sub = relay.events.listen(events.add);
  final session = await device.connect();

  /// The TV's state and place, and how long it took to say.
  Future<(String, Duration, int)?> read() async {
    final c = Stopwatch()..start();
    try {
      final t = await soap.call(control, 'AVTransport', 'GetTransportInfo', [
        ('InstanceID', '0'),
      ]);
      final p = await soap.call(control, 'AVTransport', 'GetPositionInfo', [
        ('InstanceID', '0'),
      ]);
      final parts = (p['RelTime'] ?? '0:0:0').split(':').map(int.tryParse);
      final [h, m, s] = [...parts.map((v) => v ?? 0), 0, 0, 0].sublist(0, 3);
      return (
        t['CurrentTransportState'] ?? '?',
        Duration(hours: h, minutes: m, seconds: s),
        c.elapsedMilliseconds,
      );
    } on CastException catch (e) {
      say('  read failed after ${c.elapsedMilliseconds} ms: $e');
      return null;
    }
  }

  /// Reads until [done] says so or [limit] passes: when, and the answers.
  Future<(int?, List<int>)> until(
    bool Function(String state, Duration at) done,
    Duration limit,
  ) async {
    final clock = Stopwatch()..start();
    final answers = <int>[];
    var last = '';
    while (clock.elapsed < limit) {
      final r = await read();
      if (r != null) {
        final (state, at, ms) = r;
        answers.add(ms);
        if (state != last) {
          say(
            '  ${clock.elapsedMilliseconds} ms: $state at $at '
            '(answered in $ms ms)',
          );
          last = state;
        }
        if (done(state, at)) return (clock.elapsedMilliseconds, answers);
      }
      await Future<void>.delayed(every);
    }
    return (null, answers);
  }

  try {
    final url = relay.add(FileSource(file.path), name: 'episode.mp4');
    await session.load(
      url,
      CastMedia(title: 'tv_cast network check', sizeBytes: await file.length()),
    );
    await session.play();
    final (started, startReads) = await until(
      (state, _) => state == 'PLAYING',
      const Duration(seconds: 90),
    );
    say(
      'start took ${started ?? 'over 90000'} ms; '
      'reads meanwhile: ${spread(startReads)}',
    );

    final (_, playingReads) = await until(
      (_, _) => false,
      const Duration(seconds: 8),
    );
    say('reads while playing: ${spread(playingReads)}');

    final asked = Stopwatch()..start();
    var tries = 0;
    while (true) {
      tries++;
      try {
        await session.seek(const Duration(minutes: 5));
        break;
      } on CastException catch (e) {
        if (!e.busy || tries > 30) rethrow;
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    say(
      'seek to 5:00 taken after $tries tries, ${asked.elapsedMilliseconds} ms',
    );
    final (landed, seekReads) = await until(
      (state, at) =>
          state == 'PLAYING' && at >= const Duration(minutes: 4, seconds: 50),
      const Duration(seconds: 90),
    );
    say(
      'seek landed ${landed ?? 'over 90000'} ms after it was taken; '
      'reads meanwhile: ${spread(seekReads)}',
    );
  } finally {
    try {
      await session.stop();
    } on CastException {
      // Stopped already.
    }
    await session.close();
    await sub.cancel();
    await relay.close();
  }
  final gets = events.where((e) => e.method == 'GET').toList();
  final bytes = gets.fold<int>(0, (n, e) => n + e.bytes);
  say(
    'the TV read ${(bytes / 1e6).toStringAsFixed(1)} MB in '
    '${gets.length} requests:',
  );
  for (final e in gets) {
    stdout.writeln('    $e');
  }
}
