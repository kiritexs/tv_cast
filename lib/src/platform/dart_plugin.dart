import 'cast_keep_alive.dart';

/// The plugin on Linux and macOS, where it has no native code: Flutter calls
/// [registerWith] at startup, which points [CastKeepAlive.instance] at its
/// no-op version. Finding and driving TVs and the relay are pure Dart and
/// need nothing here; `MulticastLock` and `NativeSsdpSearch` already answer
/// that they have nothing to do, and `VpnCheck` reads the adapters' names.
abstract final class TvCastDartPlugin {
  /// Called by Flutter's plugin registrant; apps don't call it.
  static void registerWith() {
    CastKeepAlive.instance = const UnsupportedCastKeepAlive();
  }
}
