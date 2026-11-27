import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One renderer's answer to a search.
class SsdpAnswer {
  const SsdpAnswer({
    required this.location,
    required this.from,
    required this.via,
    this.usn,
    this.server,
  });

  /// Where its device description is.
  final Uri location;
  final String? usn;
  final String? server;

  /// The renderer's address, and this device's address it answered on.
  final InternetAddress from;
  final InternetAddress via;
}

/// The headers of an SSDP answer, keys lower-cased; null when it isn't one.
Map<String, String>? parseSsdpAnswer(String text) {
  final lines = text.split(RegExp(r'\r?\n'));
  if (lines.isEmpty || !lines.first.toUpperCase().startsWith('HTTP/1.1 200')) {
    return null;
  }
  return {
    for (final line in lines.skip(1))
      if (line.contains(':'))
        line.substring(0, line.indexOf(':')).trim().toLowerCase(): line
            .substring(line.indexOf(':') + 1)
            .trim(),
  };
}

/// Whether an answer from [from], heard on this device's [via], may send
/// the app to [host]: an address on this network, private or link-local,
/// and this device (loopback, or its own address [via]) only in an answer
/// from this device. So an answer can't send the app's requests, and then
/// its play commands, to the internet or this device's own services.
/// Another address on the network is fine: a TV on Wi-Fi and Ethernet
/// answers from one and may name the other. SSDP and mDNS both keep to it.
bool isLanTarget(
  InternetAddress host, {
  required InternetAddress from,
  required InternetAddress via,
}) {
  final fromHere = from.isLoopback || from == via;
  if ((host.isLoopback || host == via) && !fromHere) return false;
  return host.isLoopback || host.isLinkLocal || isPrivateIPv4(host);
}

/// [text] as a renderer's answer, from [from] to this device's [via]; null
/// when it isn't one, or its location isn't an http address on this
/// network ([isLanTarget]).
SsdpAnswer? readSsdpAnswer(
  String text, {
  required InternetAddress from,
  required InternetAddress via,
}) {
  final headers = parseSsdpAnswer(text);
  final location = Uri.tryParse(headers?['location'] ?? '');
  final host = InternetAddress.tryParse(location?.host ?? '');
  if (headers == null ||
      location == null ||
      location.scheme != 'http' ||
      host == null ||
      !isLanTarget(host, from: from, via: via)) {
    return null;
  }
  return SsdpAnswer(
    location: location,
    usn: headers['usn'],
    server: headers['server'],
    from: from,
    via: via,
  );
}

/// Where a DLNA search's answers come from: [SsdpSearch] over Dart's
/// sockets, or on iOS the system's own (`NativeSsdpSearch`).
abstract interface class SsdpSearcher {
  /// The answers as they come, one per location, until [timeout].
  Stream<SsdpAnswer> search({Duration timeout});
}

/// Private IPv4 addresses: 10/8, 172.16/12, 192.168/16.
bool isPrivateIPv4(InternetAddress a) {
  if (a.type != InternetAddressType.IPv4) return false;
  final o = a.rawAddress;
  return o[0] == 10 ||
      (o[0] == 172 && o[1] >= 16 && o[1] <= 31) ||
      (o[0] == 192 && o[1] == 168);
}

/// This device's private IPv4 addresses, one per adapter.
Future<List<InternetAddress>> privateAddresses() async => [
  for (final nic in await NetworkInterface.list(type: InternetAddressType.IPv4))
    for (final a in nic.addresses)
      if (isPrivateIPv4(a)) a,
];

/// Where a search goes out from: [list] (this device's private
/// addresses), or, when it fails or finds none (some Android versions keep
/// the list from apps), any address, the system choosing the network.
Future<List<InternetAddress>> searchAddresses(
  Future<List<InternetAddress>> Function() list,
) async {
  try {
    final found = await list();
    if (found.isNotEmpty) return found;
  } on Object {
    // Fall through to any address.
  }
  return [InternetAddress.anyIPv4];
}

/// This device's address towards [host]: the one a connection to it goes
/// out from. For a search that went out from any address.
Future<InternetAddress?> addressTowards(String host, int port) async {
  try {
    final socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 3),
    );
    final local = socket.address;
    socket.destroy();
    return local;
  } on Object {
    return null;
  }
}

/// Sends [socket]'s multicast out of the adapter [local] is on, not the
/// one the system prefers: a VPN's tunnel can be that one (Windows, macOS).
/// Nothing to pin for any address.
void pinMulticast(RawDatagramSocket socket, InternetAddress local) {
  if (isAnyAddress(local) || local.type != InternetAddressType.IPv4) return;
  try {
    socket.setRawOption(
      RawSocketOption(
        RawSocketOption.levelIPv4,
        RawSocketOption.IPv4MulticastInterface,
        local.rawAddress,
      ),
    );
  } on Object {
    // The system's choice, as before.
  }
}

/// A question sent by multicast from each of this device's local
/// addresses ([localAddresses], any address when it can't list them, each
/// pinned to its adapter), answered unicast to the asking socket: SSDP, and
/// mDNS asked from an ordinary port. [read] turns a datagram and the
/// address it came in on into answers, each given once by [key], until
/// [timeout]; the question is sent [repeats] times, UDP can lose one.
Stream<T> multicastSearch<T>({
  required List<int> question,
  required InternetAddress target,
  required int port,
  required Future<List<InternetAddress>> Function() localAddresses,
  required Iterable<T> Function(Datagram datagram, InternetAddress via) read,
  required Object Function(T answer) key,
  required Duration timeout,
  required int repeats,
}) {
  final out = StreamController<T>();
  final seen = <Object>{};
  final sockets = <RawDatagramSocket>[];
  Timer? end;

  Future<void> finish() async {
    end?.cancel();
    for (final s in sockets) {
      s.close();
    }
    if (!out.isClosed) await out.close();
  }

  out.onListen = () async {
    end = Timer(timeout, () => unawaited(finish()));
    for (final local in await searchAddresses(localAddresses)) {
      RawDatagramSocket socket;
      try {
        socket = await RawDatagramSocket.bind(local, 0);
      } on SocketException {
        continue;
      }
      // Ended (cancelled, or its time up) while this one opened.
      if (out.isClosed) {
        socket.close();
        return;
      }
      sockets.add(socket);
      pinMulticast(socket, local);
      socket.listen(
        (event) {
          if (event != RawSocketEvent.read) return;
          final datagram = socket.receive();
          if (datagram == null || out.isClosed) return;
          for (final answer in read(datagram, local)) {
            if (seen.add(key(answer))) out.add(answer);
          }
        },
        // A send that fails (no route) closes the socket, Dart's way, and
        // says so here; the other addresses' sockets search on.
        onError: (Object _) {},
      );
      unawaited(() async {
        for (var i = 0; i < repeats && !out.isClosed; i++) {
          try {
            socket.send(question, target, port);
          } on SocketException {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }());
    }
  };
  out.onCancel = finish;
  return out.stream;
}

/// Whether [a] is "any address" (`0.0.0.0`): a search's fallback.
bool isAnyAddress(InternetAddress a) => a.address == '0.0.0.0';

/// The address a TV reaches this device on when no TV answered a search
/// (AirPlay): Wi-Fi first (`en0` on iPhones, `wlan…` on Android), else the
/// first private address; null off any local network.
Future<InternetAddress?> lanAddress() async {
  InternetAddress? first;
  for (final nic in await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  )) {
    final name = nic.name.toLowerCase();
    for (final a in nic.addresses) {
      if (!isPrivateIPv4(a)) continue;
      if (name == 'en0' || name.startsWith('wlan')) return a;
      first ??= a;
    }
  }
  return first;
}

/// Searches for DLNA renderers with SSDP `M-SEARCH`, from every private
/// address this device has: a PC can have several adapters on one network,
/// and only one of them may hear the TV. The answers come back unicast, so
/// no multicast lock is needed to hear them.
class SsdpSearch implements SsdpSearcher {
  SsdpSearch({
    InternetAddress? target,
    this.port = 1900,
    Future<List<InternetAddress>> Function()? localAddresses,
  }) : target = target ?? InternetAddress('239.255.255.250'),
       _localAddresses = localAddresses ?? privateAddresses;

  final InternetAddress target;
  final int port;
  final Future<List<InternetAddress>> Function() _localAddresses;

  static const searchTarget = 'urn:schemas-upnp-org:device:MediaRenderer:1';

  /// The answers as they come, one per location, until [timeout]. The
  /// search is sent [repeats] times: UDP can lose one.
  @override
  Stream<SsdpAnswer> search({
    Duration timeout = const Duration(seconds: 4),
    int repeats = 3,
  }) => multicastSearch(
    question: utf8.encode(
      'M-SEARCH * HTTP/1.1\r\n'
      'HOST: 239.255.255.250:1900\r\n'
      'MAN: "ssdp:discover"\r\n'
      'MX: 2\r\n'
      'ST: $searchTarget\r\n\r\n',
    ),
    target: target,
    port: port,
    localAddresses: _localAddresses,
    read: (datagram, via) => [
      ?readSsdpAnswer(
        utf8.decode(datagram.data, allowMalformed: true),
        from: datagram.address,
        via: via,
      ),
    ],
    key: (answer) => answer.location.toString(),
    timeout: timeout,
    repeats: repeats,
  );
}
