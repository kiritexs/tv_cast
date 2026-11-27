# Changelog

## 0.1.0

- First release.
- Finds DLNA renderers and Google Cast devices on the local network, and
  controls play, pause, seek and stop.
- A local relay serves a file, or a stream with the headers its host needs,
  to the TV.
- AirPlay on iOS through the system's route button.
- A background keep-alive while casting, on Android and Windows.
- Runs on Linux and macOS too: finding and driving TVs and the relay are
  pure Dart. There is no native code there: the plugin registers a Dart-only
  side whose keep-alive does nothing (`UnsupportedCastKeepAlive`), so no call
  throws.
- `CastKeepAlive.instance` gives the platform's own; set it to use another.
- Hardened before release: Google Cast messages are decoded within their
  bounds, and a broken one closes the connection instead of hanging; a
  Google Cast answer must name a local address, as a DLNA one must; a
  connection silent for three heartbeats is taken as gone; the relay limits
  how long a host may take, shares one probe and one refresh among the
  TV's requests, rests a link no refresh could replace, ends an item's
  fetches when it is removed, and takes a second close for the same one;
  DLNA descriptions are remembered and a search no longer waits for the
  slowest; the iOS search keeps at most 256 answers.
