/// AirPlay's route channel (`lib/src/platform/airplay.dart`): the current
/// route, and each change the platform sends.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tv_cast/airplay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(AirPlayRoute.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('the current route, from the platform', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => {'active': true, 'name': 'Living Room'},
    );
    expect(
      await AirPlayRoute().current(),
      const AirPlayState(active: true, name: 'Living Room'),
    );
  });

  test('no AirPlay here: off', () async {
    expect(await AirPlayRoute().current(), AirPlayState.off);
  });

  test('each route change comes through', () async {
    final route = AirPlayRoute();
    final states = <AirPlayState>[];
    route.changes.listen(states.add);
    for (final state in [
      {'active': true, 'name': 'Apple TV'},
      {'active': false, 'name': ''},
    ]) {
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('changed', state),
        ),
        (_) {},
      );
    }
    await Future<void>.delayed(Duration.zero);
    expect(states, [
      const AirPlayState(active: true, name: 'Apple TV'),
      AirPlayState.off,
    ]);
  });

  test('a player opened before the last one closes keeps hearing the '
      'route when the last one lets go', () async {
    final older = AirPlayRoute();
    final newer = AirPlayRoute();
    final states = <AirPlayState>[];
    newer.changes.listen(states.add);
    await older.dispose();
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('changed', {'active': true, 'name': 'Apple TV'}),
      ),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
    expect(states, [const AirPlayState(active: true, name: 'Apple TV')]);
    await newer.dispose();
  });

  test(
    'let go of: its changes end, and the platform is no longer heard',
    () async {
      final route = AirPlayRoute();
      var ended = false;
      route.changes.listen((_) {}, onDone: () => ended = true);
      await route.dispose();
      expect(ended, isTrue);
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('changed', {'active': true, 'name': 'x'}),
        ),
        (_) {},
      );
    },
  );
}
