/// Linux and macOS: the plugin's Dart-only side, whose keep-alive does
/// nothing, and the platform default it sets.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tv_cast/platform.dart';

const _notice = CastNotice(
  title: 'Episode 11',
  channelName: 'Casting',
  playLabel: 'Play',
  pauseLabel: 'Pause',
  stopLabel: 'Stop casting',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the default is the channel one until a platform sets another', () {
    expect(CastKeepAlive.instance, isA<MethodChannelCastKeepAlive>());
    expect(CastKeepAlive.instance, same(CastKeepAlive.instance));
  });

  test('registerWith points it at the no-op version', () {
    TvCastDartPlugin.registerWith();
    expect(CastKeepAlive.instance, isA<UnsupportedCastKeepAlive>());
  });

  test('the no-op keep-alive holds nothing and has no controls', () async {
    const keepAlive = UnsupportedCastKeepAlive();
    expect(await keepAlive.hold(_notice), isFalse);
    await keepAlive.update(_notice);
    await keepAlive.release();
    await expectLater(keepAlive.actions, emitsDone);
  });
}
