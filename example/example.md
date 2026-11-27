# tv_cast examples

Two scripts in this folder run with plain `dart run`, from the package's
folder, with a DLNA TV on the same network:

```bash
dart run example/cast_file.dart path/to/video.mp4 [part of the TV's name]
dart run example/network_check.dart [--play path/to/video.mp4]
```

- [`cast_file.dart`](cast_file.dart) finds the TV, serves the file through
  the relay, then plays, pauses, resumes, seeks and stops it, printing what
  the TV did after each step.
- [`network_check.dart`](network_check.dart) measures the network between
  this computer and the TVs, for when a cast is slow.

The core of `cast_file.dart`:

```dart
import 'dart:io';

import 'package:tv_cast/tv_cast.dart';

Future<void> main(List<String> args) async {
  final path = args.first;
  final tvs = await findCastDevices(timeout: const Duration(seconds: 4)).toList();
  if (tvs.isEmpty) return print('No TV found.');
  final tv = tvs.first;

  final relay = await MediaRelay.start(tv.localAddress);
  final url = relay.add(FileSource(path), name: 'video.mp4');

  final session = await tv.connect();
  await session.load(
    url,
    CastMedia(title: 'tv_cast example', sizeBytes: File(path).lengthSync()),
  );
  await session.play();
  await Future<void>.delayed(const Duration(seconds: 10));
  await session.stop();
  await session.close();
  await relay.close();
}
```

Inside a Flutter app, also hold `MulticastLock` while searching on Android,
use `NativeSsdpSearch` on iOS, and hold `CastKeepAlive` while casting; the
README shows each.
