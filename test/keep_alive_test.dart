/// The keep-alive's channel (`lib/src/platform/cast_keep_alive.dart`): what
/// it sends the platform, what it makes of the answers, and the
/// notification's controls coming back.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tv_cast/platform.dart';

const _notice = CastNotice(
  title: 'Bleach · EP 11',
  text: 'Playing on [TV] Samsung',
  playing: false,
  channelName: 'Casting',
  playLabel: 'Play',
  pauseLabel: 'Pause',
  stopLabel: 'Stop casting',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(MethodChannelCastKeepAlive.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  void answer(Object? Function(MethodCall call) reply) =>
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return reply(call);
      });

  setUp(calls.clear);
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('hold sends the notice; held only when the platform says so', () async {
    final keepAlive = MethodChannelCastKeepAlive();
    answer((_) => 'held');
    expect(await keepAlive.hold(_notice), isTrue);
    expect(calls.single.method, 'hold');
    expect(calls.single.arguments, _notice.toMap());

    answer((_) => 'refused');
    expect(await keepAlive.hold(_notice), isFalse);
  });

  test('a platform with nothing to hold: not held, and update and release '
      'do nothing', () async {
    final keepAlive = MethodChannelCastKeepAlive();
    expect(await keepAlive.hold(_notice), isFalse);
    await keepAlive.update(_notice);
    await keepAlive.release();
  });

  test('a platform that refuses with an error: not held, and update and '
      'release throw nothing', () async {
    final keepAlive = MethodChannelCastKeepAlive();
    answer((_) => throw PlatformException(code: 'refused'));
    expect(await keepAlive.hold(_notice), isFalse);
    await keepAlive.update(_notice);
    await keepAlive.release();
    expect(calls.map((c) => c.method), ['hold', 'update', 'release']);
  });

  test('update and release reach the platform', () async {
    final keepAlive = MethodChannelCastKeepAlive();
    answer((_) => null);
    await keepAlive.update(_notice);
    await keepAlive.release();
    expect(calls.map((c) => c.method), ['update', 'release']);
  });

  test('the notification\'s controls come back as actions', () async {
    final keepAlive = MethodChannelCastKeepAlive();
    final actions = <CastAction>[];
    keepAlive.actions.listen(actions.add);
    for (final method in ['play', 'pause', 'stop', 'unknown']) {
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
        (_) {},
      );
    }
    await Future<void>.delayed(Duration.zero);
    expect(actions, [CastAction.play, CastAction.pause, CastAction.stop]);
  });
}
