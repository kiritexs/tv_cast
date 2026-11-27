import 'dart:async';

import 'cast_device.dart';
import 'dlna/dlna_renderer.dart';
import 'googlecast/google_cast.dart';

/// Every TV that answers within [timeout], whatever it speaks: DLNA and
/// Google Cast searched at once, each device as soon as it is found. Pass
/// the [dlna] discovery kept for the app's life, so the descriptions it
/// remembers aren't read again by every search; and [googleCast] likewise.
Stream<CastDevice> findCastDevices({
  Duration timeout = const Duration(seconds: 4),
  List<Stream<CastDevice> Function(Duration timeout)>? searches,
  DlnaDiscovery? dlna,
  GoogleCastDiscovery? googleCast,
}) {
  final out = StreamController<CastDevice>();
  final subs = <StreamSubscription<CastDevice>>[];
  var running = 0;
  out.onListen = () {
    for (final search
        in searches ??
            [
              (t) => (dlna ?? DlnaDiscovery()).find(timeout: t),
              (t) => (googleCast ?? GoogleCastDiscovery()).find(timeout: t),
            ]) {
      running++;
      subs.add(
        search(timeout).listen(
          out.add,
          // One search failing doesn't end the other.
          onError: (Object _) {},
          onDone: () {
            if (--running == 0 && !out.isClosed) unawaited(out.close());
          },
        ),
      );
    }
  };
  out.onCancel = () async {
    for (final sub in subs) {
      await sub.cancel();
    }
  };
  return out.stream;
}
