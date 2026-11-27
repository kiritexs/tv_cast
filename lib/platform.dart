/// The parts that go through the platform: keeping the app serving and
/// driving a TV while it isn't in front, Android's multicast lock and VPN
/// check, and iOS's DLNA search. Its own library, one of the two that need
/// Flutter (the other is `airplay.dart`): `tv_cast.dart` stays plain Dart,
/// so scripts such as `example/cast_file.dart` run with `dart run`.
library;

export 'src/platform/cast_keep_alive.dart';
export 'src/platform/dart_plugin.dart';
export 'src/platform/multicast_lock.dart';
export 'src/platform/native_ssdp.dart';
export 'src/platform/vpn_check.dart';
