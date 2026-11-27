import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Where the audio and video go now: an AirPlay device, by its name, or
/// this device.
class AirPlayState {
  const AirPlayState({required this.active, this.name = ''});

  static const off = AirPlayState(active: false);

  final bool active;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is AirPlayState && other.active == active && other.name == name;

  @override
  int get hashCode => Object.hash(active, name);

  @override
  String toString() => active ? 'AirPlay($name)' : 'AirPlay(off)';
}

/// AirPlay on iOS: the system moves the player's video to the TV; this says
/// when it has, from the audio route, so the app can feed the player
/// through a `MediaRelay` (the TV fetches the video itself, without the
/// app's headers).
class AirPlayRoute {
  /// Hears the route through [channel] (the plugin's, by default), taking it
  /// over from any route made before.
  AirPlayRoute({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_fromPlatform);
    _holders[_channel.name] = this;
  }

  /// The route hearing each channel: the newest. A player opened before
  /// the last one closes takes it over.
  static final _holders = <String, AirPlayRoute>{};

  static const channelName = 'tv_cast/airplay';

  /// Only iOS has AirPlay here.
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  final MethodChannel _channel;
  final _changes = StreamController<AirPlayState>.broadcast();

  /// Each change of route; the same state may come twice.
  Stream<AirPlayState> get changes => _changes.stream;

  /// Stops hearing the route: [changes] ends, and the channel's handler
  /// goes unless a newer route holds it.
  Future<void> dispose() async {
    if (identical(_holders[_channel.name], this)) {
      _holders.remove(_channel.name);
      _channel.setMethodCallHandler(null);
    }
    await _changes.close();
  }

  Future<AirPlayState> current() async {
    try {
      return _parse(await _channel.invokeMapMethod<String, Object?>('current'));
    } on MissingPluginException {
      return AirPlayState.off;
    }
  }

  static AirPlayState _parse(Map<Object?, Object?>? map) => AirPlayState(
    active: map?['active'] == true,
    name: map?['name'] as String? ?? '',
  );

  Future<void> _fromPlatform(MethodCall call) async {
    if (call.method != 'changed' || _changes.isClosed) return;
    _changes.add(_parse(call.arguments as Map<Object?, Object?>?));
  }
}

/// The system's AirPlay button (`AVRoutePickerView`), video devices first;
/// nothing off iOS. [tint] and [activeTint] colour its icon.
class AirPlayButton extends StatelessWidget {
  /// The button, [size] logical pixels square.
  const AirPlayButton({
    super.key,
    required this.tint,
    required this.activeTint,
    this.size = 24,
  });

  /// The icon's colour while the video plays here.
  final Color tint;

  /// The icon's colour while the video goes to an AirPlay device.
  final Color activeTint;

  /// The button's width and height.
  final double size;

  @override
  Widget build(BuildContext context) {
    if (!AirPlayRoute.supported) return const SizedBox.shrink();
    return SizedBox.square(
      dimension: size,
      child: UiKitView(
        viewType: 'tv_cast/airplay_button',
        creationParams: {
          'tint': tint.toARGB32(),
          'activeTint': activeTint.toARGB32(),
        },
        creationParamsCodec: const StandardMessageCodec(),
      ),
    );
  }
}
