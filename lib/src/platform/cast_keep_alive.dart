import 'dart:async';

import 'package:flutter/services.dart';

/// What the system shows while a TV plays, in the app's own words: a title,
/// a line, whether it plays (which control the notification offers), and
/// the controls' and the notification group's names.
class CastNotice {
  const CastNotice({
    required this.title,
    this.text = '',
    this.playing = true,
    required this.channelName,
    required this.playLabel,
    required this.pauseLabel,
    required this.stopLabel,
  });

  final String title;
  final String text;
  final bool playing;

  /// Android's notification channel.
  final String channelName;
  final String playLabel;
  final String pauseLabel;
  final String stopLabel;

  Map<String, Object?> toMap() => {
    'title': title,
    'text': text,
    'playing': playing,
    'channelName': channelName,
    'playLabel': playLabel,
    'pauseLabel': pauseLabel,
    'stopLabel': stopLabel,
  };

  @override
  bool operator ==(Object other) =>
      other is CastNotice &&
      other.title == title &&
      other.text == text &&
      other.playing == playing &&
      other.channelName == channelName &&
      other.playLabel == playLabel &&
      other.pauseLabel == pauseLabel &&
      other.stopLabel == stopLabel;

  @override
  int get hashCode => Object.hash(
    title,
    text,
    playing,
    channelName,
    playLabel,
    pauseLabel,
    stopLabel,
  );
}

/// A control pressed outside the app: the notification's.
enum CastAction { play, pause, stop }

/// Keeps the app serving and driving a TV while it isn't in front: on
/// Android a media playback foreground service with a notification and its
/// controls, a partial wake lock and a Wi-Fi lock; on Windows a power
/// request, so the PC doesn't sleep under the TV. Nothing elsewhere.
abstract interface class CastKeepAlive {
  /// This platform's keep-alive, made on first use: the plugin's own
  /// ([MethodChannelCastKeepAlive]) on Android, iOS and Windows, and
  /// [UnsupportedCastKeepAlive] on Linux and macOS, which have no native
  /// side. Set it to use another (a fake in tests).
  static CastKeepAlive get instance =>
      _instance ??= MethodChannelCastKeepAlive();
  static set instance(CastKeepAlive value) => _instance = value;
  static CastKeepAlive? _instance;

  /// A TV plays: true once held, false when the system refused or this
  /// platform has nothing to hold.
  Future<bool> hold(CastNotice notice);

  /// What is shown while held, again: playing or paused, another video.
  Future<void> update(CastNotice notice);

  /// Casting ended.
  Future<void> release();

  /// The notification's controls.
  Stream<CastAction> get actions;
}

/// [CastKeepAlive] over the plugin's channel, `tv_cast/keep_alive`.
class MethodChannelCastKeepAlive implements CastKeepAlive {
  MethodChannelCastKeepAlive({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_fromPlatform);
  }

  static const channelName = 'tv_cast/keep_alive';

  final MethodChannel _channel;
  final _actions = StreamController<CastAction>.broadcast();

  @override
  Stream<CastAction> get actions => _actions.stream;

  @override
  Future<bool> hold(CastNotice notice) async {
    try {
      final answer = await _channel.invokeMethod<String>(
        'hold',
        notice.toMap(),
      );
      return answer == 'held';
    } on MissingPluginException {
      return false;
    } on PlatformException {
      // The system refused (a notification or service it won't start).
      return false;
    }
  }

  @override
  Future<void> update(CastNotice notice) async {
    try {
      await _channel.invokeMethod<void>('update', notice.toMap());
    } on MissingPluginException {
      // Nothing is shown.
    } on PlatformException {
      // The notice stays as it was.
    }
  }

  @override
  Future<void> release() async {
    try {
      await _channel.invokeMethod<void>('release');
    } on MissingPluginException {
      // Nothing was held.
    } on PlatformException {
      // Already let go.
    }
  }

  Future<void> _fromPlatform(MethodCall call) async {
    final action = switch (call.method) {
      'play' => CastAction.play,
      'pause' => CastAction.pause,
      'stop' => CastAction.stop,
      _ => null,
    };
    if (action != null) _actions.add(action);
  }
}

/// [CastKeepAlive] where the platform has nothing to hold (Linux, macOS):
/// [hold] is false, the rest does nothing, and no control is ever pressed.
/// Casting goes on as long as the app runs.
class UnsupportedCastKeepAlive implements CastKeepAlive {
  const UnsupportedCastKeepAlive();

  @override
  Stream<CastAction> get actions => const Stream.empty();

  @override
  Future<bool> hold(CastNotice notice) async => false;

  @override
  Future<void> update(CastNotice notice) async {}

  @override
  Future<void> release() async {}
}
