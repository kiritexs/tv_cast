// Casts a video file to the first DLNA TV found, through tv_cast: the
// manual check on a real TV. Plays, pauses, resumes, seeks to 5:00 and
// 1:00, stops, and prints what the TV did.
//
//   dart run example/cast_file.dart <file.mp4> [part of the TV's name]
import 'dart:async';
import 'dart:io';

import 'package:tv_cast/tv_cast.dart';

final _t0 = DateTime.now();
void say(String s) => stdout.writeln(
  '+${(DateTime.now().difference(_t0).inMilliseconds / 1000).toStringAsFixed(1)}s $s',
);

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run example/cast_file.dart <file> [tv name]');
    exit(64);
  }
  final file = File(args.first);
  final want = args.length > 1 ? args[1].toLowerCase() : '';

  say('searching…');
  final devices = await DlnaDiscovery().find().toList();
  for (final d in devices) {
    say(
      'found "${d.name}" (${d.maker} ${d.model}) via ${d.localAddress.address}',
    );
  }
  final tv = devices
      .where((d) => d.name.toLowerCase().contains(want))
      .firstOrNull;
  if (tv == null) {
    say('no TV${want.isEmpty ? '' : ' matching "$want"'}: is it on?');
    exit(2);
  }

  final relay = await MediaRelay.start(tv.localAddress);
  relay.events.listen((e) => say('  relay: $e'));
  final url = relay.add(FileSource(file.path), name: 'episode.mp4');
  final session = await tv.connect();

  Future<void> until(bool Function(CastStatus s) done, String what) async {
    final started = DateTime.now();
    while (DateTime.now().difference(started) < const Duration(seconds: 40)) {
      final s = await session.poll();
      if (done(s)) {
        say(
          '$what took ${DateTime.now().difference(started).inMilliseconds} ms: $s',
        );
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    say('$what: not within 40 s');
  }

  Future<void> watch(int seconds) async {
    final sub = session.watch().listen((s) => say('  $s'));
    await Future<void>.delayed(Duration(seconds: seconds));
    await sub.cancel();
  }

  await session.load(
    url,
    CastMedia(title: file.uri.pathSegments.last, sizeBytes: file.lengthSync()),
  );
  await session.play();
  await until((s) => s.state == CastState.playing, 'start');
  await watch(6);
  await session.pause();
  await until((s) => s.state == CastState.paused, 'pause');
  await session.play();
  await until((s) => s.state == CastState.playing, 'resume');
  for (final at in [const Duration(minutes: 5), const Duration(minutes: 1)]) {
    await session.seek(at);
    await until(
      (s) =>
          s.state == CastState.playing &&
          (s.position - at).inSeconds.abs() <= 8,
      'seek to ${at.inMinutes}:00',
    );
    await watch(4);
  }
  await session.stop();
  await session.close();
  await relay.close();
  say('done');
  exit(0);
}
