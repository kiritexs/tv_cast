# tv_cast

Send a video from a phone or PC to a TV on the same network, and control it
from the app. `tv_cast` finds TVs with DLNA (SSDP) and Google Cast (mDNS),
serves the video from the device through a small local HTTP relay (a file, or
a stream fetched with the headers its host needs, which never reach the TV),
and drives play, pause, seek, stop and volume. A native keep-alive keeps the
app serving while it is in the background (Android, Windows), and on iOS the
package reports the AirPlay route and shows the system's AirPlay button.

The search, the relay and the DLNA and Google Cast clients are plain Dart
(`dart:io`). Only the keep-alive, the Android multicast lock, the VPN check,
the iOS search and AirPlay go through the platform.

## When to use it

Choose it when your app plays video it fetches itself and should send it to
a TV without a vendor SDK.

- DLNA and Google Cast in one API, on Android, iOS, Windows, Linux and macOS
  (see [Platform support](#platform-support) for iOS's limits).
- The relay serves a downloaded file, or re-streams a remote one with the
  headers or cookies its host needs, so the TV never needs them.
- Casting carries on while your app is in the background on Android and
  Windows, with play, pause and stop in the Android notification.
- On iOS, the system's own AirPlay button and route.

---

## Platform support

| | Android | iOS | Linux | macOS | Windows |
|---|---|---|---|---|---|
| DLNA TVs: search and control | Yes | Yes, through the native search (see [iOS](#ios)) | Yes | Yes | Yes |
| Google Cast: search and control | Yes | Control yes; the built-in search needs Apple's multicast entitlement (see [iOS](#ios)) | Yes | Yes | Yes |
| AirPlay: route state and button | - | Yes | - | - | - |
| Relay (file or stream) | Yes | Yes | Yes | Yes | Yes |
| Background keep-alive | Foreground service with a notification (play, pause, stop), wake lock, Wi-Fi lock | None; the app has to stay running | None (`hold` returns `false`) | None (`hold` returns `false`) | Power request, so the PC does not sleep |
| Multicast lock for the search | Yes | - | - | - | - |
| VPN check | Asks Android; tells a VPN that allows bypassing from one that does not | Guessed from adapter names | Guessed from adapter names | Guessed from adapter names | Guessed from adapter names |

Linux and macOS have no native code: the plugin registers a Dart-only side
there, whose keep-alive does nothing (`UnsupportedCastKeepAlive`), and every
platform call answers that it has nothing to do instead of throwing. Web is not
supported and cannot be: browsers give a page no UDP for the search and no way
to serve the relay. `package:tv_cast/tv_cast.dart` imports nothing but
`dart:io`, so scripts run with `dart run`.

### What has been tested on devices

- **Checked on real hardware:** DLNA on a Samsung TV, from Android, Windows
  and an iPhone. That covers search, play, seek, pause from the TV's remote,
  the TV switched off mid-video, the phone leaving the Wi-Fi, 30 minutes with
  the phone locked, and the Android keep-alive's notification controls.
- **Needs more testing:** Google Cast (Chromecast, Google TV), AirPlay, DLNA
  TVs from other makers, and everything on Linux and macOS. These are covered
  by automated tests, with fake TVs speaking the real protocols, but not yet
  checked on real devices. Reports and fixes are welcome.

TVs differ, especially DLNA ones. Expect to meet some that need a different
content type or answer slowly.

---

## Install

```yaml
dependencies:
  tv_cast: ^0.1.0
```

Three libraries:

| Import | Needs Flutter | Holds |
|---|---|---|
| `package:tv_cast/tv_cast.dart` | No | Search, relay, sessions, `VpnState` |
| `package:tv_cast/platform.dart` | Yes | `CastKeepAlive`, `MulticastLock`, `VpnCheck`, `NativeSsdpSearch`, `TvCastDartPlugin` |
| `package:tv_cast/airplay.dart` | Yes | `AirPlayRoute`, `AirPlayButton` |

Requirements: Dart 3.10 or later and the Flutter SDK (the package is a
Flutter plugin). iOS 13 or later (Swift Package Manager and CocoaPods are
both supported). Android's `minSdk` and `compileSdk` follow Flutter's. Linux
and macOS need nothing beyond Flutter's own minimums.

---

## Platform setup

Only what the package's code needs.

### Android

The plugin's own manifest is merged into your app's. It adds these
permissions, and the keep-alive service (`CastKeepAliveService`, of the
`mediaPlayback` type, not exported):

| Permission | Used for |
|---|---|
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK` | The keep-alive service (Android 14 needs the type and its permission) |
| `WAKE_LOCK` | The partial wake lock and the Wi-Fi lock held while it runs |
| `CHANGE_WIFI_MULTICAST_STATE` | `MulticastLock` |
| `ACCESS_NETWORK_STATE` | `VpnCheck` |

What your app still does:

- Declare `android.permission.INTERNET`. Opening the relay's and the
  search's sockets needs it, and Flutter's template adds it to debug and
  profile builds only.
- To show the keep-alive's notification and its controls on Android 13 and
  later, declare `android.permission.POST_NOTIFICATIONS` and ask for it at
  runtime. The package does neither. Without it the service still runs, but
  the notification is not shown or updated.
- Call `CastKeepAlive.hold` while the app is in front. Android 12 and later
  refuse to start the service otherwise; `hold` then returns `false`.

### iOS

Add to `Info.plist`:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Finds TVs on your Wi-Fi and plays your videos on them.</string>
```

iOS asks for the Local Network permission the first time the app talks to
devices on the network. Both the search and the TV fetching from the relay
need it. If the person says no, no TV is found.

Also:

- **DLNA search.** The default search multicasts from Dart's sockets, and iOS
  allows that only with Apple's multicast entitlement
  (`com.apple.developer.networking.multicast`), which a free developer
  account cannot have. `NativeSsdpSearch` goes around it: it asks the group
  and every neighbour on the Wi-Fi's /24 directly, which needs only the Local
  Network permission. Pass it to `DlnaDiscovery` as shown in
  [Usage](#find-tvs-on-ios).
- **Google Cast search.** It is mDNS by multicast from Dart's sockets, which
  iOS allows only with the multicast entitlement, so expect it to find
  nothing without it. There is no native fallback. You can still build a
  `GoogleCastDevice` yourself from an address you know.
- **Bonjour keys.** The package does not use Bonjour APIs, so
  `NSBonjourServices` is not needed for it.
- **AirPlay.** The route button and the route state need no keys. If your own
  `AVPlayer` loads the relay's `http://` address (the AirPlay case below), add
  an App Transport Security exception such as `NSAllowsLocalNetworking`.
- **Background.** The plugin holds nothing on iOS: the keep-alive is a no-op
  there (`hold` returns `false`). During AirPlay the system's audio session
  keeps the player going. The relay serving a DLNA or Google Cast TV runs
  only while iOS lets the app run, so keep the app in front, or give it a
  background mode of your own.

### Windows

Nothing to configure. The first time the relay starts, Windows Defender
Firewall may ask whether to let the app accept connections; allow it on
private networks, or the TV cannot reach the relay.

### macOS

A sandboxed macOS app (Flutter's default) needs both network entitlements:
the client one to talk to TVs, the server one for the relay and to hear the
search's answers. Add them to `macos/Runner/DebugProfile.entitlements` and
`Release.entitlements`:

```xml
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.network.server</key>
<true/>
```

From macOS 15 the system asks for the Local Network permission the first time
the app talks to devices on the network; add `NSLocalNetworkUsageDescription`
to `macos/Runner/Info.plist` with a line saying why, as on iOS. If the person
says no, no TV is found. macOS needs no multicast entitlement.

### Linux

Nothing to configure. A host firewall (`ufw`, `firewalld`) that drops
incoming connections stops the TV reaching the relay and can hide the
search's answers; allow the app on the local network.

---

## Usage

### Find TVs and cast a file

```dart
import 'dart:io';

import 'package:tv_cast/tv_cast.dart';

Future<void> castFile(String path) async {
  // DLNA and Google Cast are searched at once; each TV arrives as it is found.
  final tvs = await findCastDevices(
    timeout: const Duration(seconds: 4),
  ).toList();
  if (tvs.isEmpty) return; // none found, or the network hides them
  final tv = tvs.first; // a real app lets the person pick

  // Serve the file on the address the TV answered on.
  final relay = await MediaRelay.start(tv.localAddress);
  final url = relay.add(FileSource(path), name: 'video.mp4');

  final session = await tv.connect();
  await session.load(
    url,
    CastMedia(title: 'My video', sizeBytes: File(path).lengthSync()),
  );
  await session.play();

  // A reading every second: state, position, duration.
  final readings = session.watch().listen(print);

  await session.seek(const Duration(minutes: 5));
  await session.pause();

  await readings.cancel();
  await session.stop();
  await session.close();
  await relay.close();
}
```

`CastSession` also has `poll()` for one reading, `volume()`, `setVolume()` and
`setMuted()`. A command the TV refuses throws `CastException`; its `busy` is
true when the TV is between states and the same command may work a moment
later.

### Stream from another host

An `UpstreamSource` is fetched with its own headers as the TV asks for the
bytes, so the cookie and user agent stay on this device.

```dart
final url = relay.add(
  UpstreamSource(
    (
      url: Uri.parse('https://cdn.example.com/video.mp4'),
      headers: {'User-Agent': '...', 'Referer': 'https://example.com/'},
    ),
    // Optional: a fresh link when this one expires (401, 403, 410, or a
    // page instead of the video).
    refresh: () async => (
      url: Uri.parse('https://cdn.example.com/video.mp4?token=new'),
      headers: {'User-Agent': '...', 'Referer': 'https://example.com/'},
    ),
  ),
);
```

The host must tell the stream's length (the relay asks for one byte first),
because a TV needs the length to seek.

The requests a TV makes at once share one length probe and one `refresh`.
A `refresh` that throws, gives `null` (none can be had), or gives a link the
host refuses too answers the TV `502`, and the item then answers `502` at
once for `refreshPause` (30 s) without asking the host or `refresh` again.
A host has `upstreamWithin` (20 s) to answer and may go quiet for
`upstreamIdle` (30 s) mid-answer; all three are `MediaRelay.start`
parameters. `relay.remove(url)` ends the item's fetches still open.

### Find TVs on iOS

```dart
import 'package:tv_cast/platform.dart';
import 'package:tv_cast/tv_cast.dart';

final tvs = findCastDevices(
  searches: [
    (timeout) => DlnaDiscovery(search: NativeSsdpSearch()).find(timeout: timeout),
  ],
);
```

A `DlnaDiscovery` remembers each TV's device description for `remember`
(5 minutes), so keep one for as long as the app searches (pass it to
`findCastDevices(dlna: ...)`): a TV busy playing is slow to send it again.
A search waits at most `lateBy` (2 s) past its window for slow
descriptions, each of which has `describeWithin` (4 s).

### Android: the multicast lock and the VPN check

```dart
import 'package:tv_cast/platform.dart';

await MulticastLock.hold(); // many phones drop multicast while the Wi-Fi saves power
try {
  // search
} finally {
  await MulticastLock.release();
}

final vpn = await VpnCheck.state();
if (vpn != VpnState.none) {
  // `on`: a VPN may hide the TVs; its "Bypass LAN" switch may fix it.
  // `locked` (Android): it refuses apps the Wi-Fi, only its own switch helps.
}
```

### Keep casting in the background

```dart
import 'package:tv_cast/platform.dart';

// The plugin's channel on Android, iOS and Windows; a no-op on Linux and macOS.
final keepAlive = CastKeepAlive.instance;

// The notification's controls, pressed outside the app.
keepAlive.actions.listen((action) {
  // CastAction.play, CastAction.pause or CastAction.stop
});

final held = await keepAlive.hold(
  const CastNotice(
    title: 'Playing on Living room TV',
    text: 'My video',
    channelName: 'Casting', // Android's notification channel
    playLabel: 'Play',
    pauseLabel: 'Pause',
    stopLabel: 'Stop',
  ),
);

// Later: show paused, or another video, then let go.
await keepAlive.update(
  const CastNotice(
    title: 'Playing on Living room TV',
    playing: false,
    channelName: 'Casting',
    playLabel: 'Play',
    pauseLabel: 'Pause',
    stopLabel: 'Stop',
  ),
);
await keepAlive.release();
```

You give the texts, so they follow your app's language. On Windows nothing is
shown; the notice's title becomes the reason of the power request (visible in
`powercfg /requests`).

### AirPlay (iOS)

AirPlay moves your own player's video to the TV; `tv_cast` tells you when it
has and shows the system's button. The TV then fetches the video itself,
without your headers, so feed the player a relay URL while the route is
active (`lanAddress()` gives a local address to start the relay on).

```dart
import 'package:flutter/widgets.dart';
import 'package:tv_cast/airplay.dart';

final route = AirPlayRoute();
route.changes.listen((state) {
  // state.active, state.name
});
final now = await route.current();

// In a widget tree; empty off iOS.
const button = AirPlayButton(
  tint: Color(0xFFFFFFFF),
  activeTint: Color(0xFF7C4DFF),
);

await route.dispose();
```

---

## Notes and limits

- **Same network.** The TV and the device must be on the same network. Guest
  networks and routers with client isolation block it.
- **VPNs.** A VPN that takes the whole network hides the TVs from every app.
  Most VPN apps have a switch that leaves the local network out ("Bypass
  LAN"). `VpnCheck.state()` says when one is probably in the way.
- **Formats.** The relay serves the bytes as they are and tells the TV the
  `contentType` you give (`video/mp4` by default). It does not transcode, and
  it does not rewrite HLS or DASH playlists, so a single progressive file is
  what it is for. The TV has to be able to decode that file. DLNA TVs report
  their position in whole seconds.
- **Security.** The relay is plain HTTP on the local address. Each item has
  its own unguessable URL, and the relay answers only clients on the local
  network (private, link-local or loopback addresses). A DLNA answer counts
  only when it names a local `http` address, and its control URLs must stay
  on the TV's host. A Google Cast answer counts only when it names a local
  address (and a port that isn't 0); this device's own address counts only
  in an answer from this device, for both. A Google Cast device presents
  its own certificate, which only Google's SDK checks; the connection takes
  it as it is, on the local network. A broken Cast message closes the
  connection, and one that says nothing for three heartbeats is taken as
  gone; the next command connects again.
- **Google Cast.** Playback uses Google's Default Media Receiver; nothing is
  installed on the device and no registration is needed.
- **API surface.** The classes in `lib/src` that the three libraries do not
  export can change at any time.

---

## Examples

From this package's folder, with a DLNA TV on the same network:

```bash
dart run example/cast_file.dart path/to/video.mp4 [part of the TV's name]
dart run example/network_check.dart [--play path/to/video.mp4]
```

`cast_file.dart` plays a file, pauses, resumes, seeks and stops, printing what
the TV did. `network_check.dart` measures the network between the PC and the
TVs, for a slow cast.

---

`tv_cast` is not affiliated with Google, Apple or the DLNA organisation.
Chromecast and Google Cast are trademarks of Google, AirPlay of Apple.

---

## License

MPL-2.0, © 2026 Kiritex.
