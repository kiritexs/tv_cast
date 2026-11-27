import 'dart:async';
import 'dart:io';

/// The ways this package reaches a TV.
enum CastProtocol { dlna, googleCast }

/// A TV found on the network.
abstract interface class CastDevice {
  /// Stable while the TV keeps its identity (DLNA: its UDN).
  String get id;

  /// What the TV calls itself, e.g. "[TV]Samsung LED49".
  String get name;

  /// Its maker and model, when it says.
  String get maker;
  String get model;

  CastProtocol get protocol;

  /// This device's address the TV answered on: the relay serves from here.
  InternetAddress get localAddress;

  Future<CastSession> connect();
}

/// What the TV is told about the video.
class CastMedia {
  const CastMedia({
    required this.title,
    this.contentType = 'video/mp4',
    this.sizeBytes,
  });

  final String title;
  final String contentType;
  final int? sizeBytes;
}

/// What the TV is doing.
enum CastState {
  /// Nothing loaded.
  idle,

  /// Opening what was loaded, or buffering.
  loading,
  playing,
  paused,
  stopped,

  /// An answer this package doesn't know.
  unknown,
}

/// One reading of the TV.
class CastStatus {
  const CastStatus({
    required this.state,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.sampledAt,
  });

  final CastState state;

  /// Where it is; DLNA TVs report whole seconds.
  final Duration position;

  /// The video's length; zero until the TV knows it.
  final Duration duration;

  /// About when the TV read [position]: a slow TV's answer comes seconds
  /// after it. Null: when it came.
  final DateTime? sampledAt;

  @override
  String toString() => 'CastStatus($state, $position / $duration)';
}

/// The TV's own volume: [level] from 0 to 1, and whether it is muted.
class CastVolume {
  const CastVolume({required this.level, this.muted = false});

  final double level;
  final bool muted;

  @override
  bool operator ==(Object other) =>
      other is CastVolume && other.level == level && other.muted == muted;

  @override
  int get hashCode => Object.hash(level, muted);

  @override
  String toString() =>
      'CastVolume(${(level * 100).round()}%'
      '${muted ? ', muted' : ''})';
}

/// Control of one TV.
abstract interface class CastSession {
  CastDevice get device;

  /// Tells the TV to play [url] (on this device's relay) next; it opens it
  /// when told to [play].
  Future<void> load(Uri url, CastMedia media);

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> stop();

  /// One reading of the TV.
  Future<CastStatus> poll();

  /// The TV's volume; null when it has none this package can reach.
  Future<CastVolume?> volume();

  /// Sets the TV's volume, [level] from 0 to 1.
  Future<void> setVolume(double level);
  Future<void> setMuted(bool muted);

  /// A reading every [every] until [close]; a reading that fails is skipped.
  Stream<CastStatus> watch({Duration every = const Duration(seconds: 1)});

  /// Stops watching; the TV keeps whatever it is doing.
  Future<void> close();
}

/// [session]'s readings every [every] until [closed]; a reading that fails
/// is skipped. Each session's `watch`.
Stream<CastStatus> readingsOf(
  CastSession session,
  Duration every,
  bool Function() closed,
) async* {
  while (!closed()) {
    try {
      yield await session.poll();
    } on Object {
      // One missed reading (refused, a dropped socket, an answer that
      // didn't parse); the next may answer. Never the end of the watch.
    }
    if (closed()) return;
    await Future<void>.delayed(every);
  }
}

/// The TV refused a command, or couldn't be reached.
class CastException implements Exception {
  const CastException(
    this.action,
    this.message, {
    this.status,
    this.code,
    bool busy = false,
  }) : _busy = busy;

  final String action;
  final String message;

  /// The HTTP status, and the protocol's own error code, when there were any.
  final int? status;
  final int? code;
  final bool _busy;

  /// The TV is between states and refused for now: UPnP's 701 "Transition
  /// not available" and 705 "Transport is locked", Cast's invalid player
  /// state. The same command may work once it has settled.
  bool get busy => _busy || code == 701 || code == 705;

  @override
  String toString() =>
      'CastException($action: $message'
      '${status == null ? '' : ', HTTP $status'}'
      '${code == null ? '' : ', code $code'})';
}
