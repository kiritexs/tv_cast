import 'dart:io';
import 'dart:typed_data';

import '../dlna/ssdp.dart' show isLanTarget, multicastSearch, privateAddresses;
import 'dns.dart';

/// One Google Cast device that answered: its address and port, and what
/// its TXT record says (`fn` its name, `md` its model, `id` its id).
class MdnsAnswer {
  const MdnsAnswer({
    required this.instance,
    required this.address,
    required this.port,
    required this.txt,
    required this.via,
  });

  final String instance;
  final InternetAddress address;
  final int port;
  final Map<String, String> txt;

  /// This device's address the answer came in on.
  final InternetAddress via;
}

/// Asks for `_googlecast._tcp.local` with mDNS (RFC 6762), from every
/// private address this device has. The question goes from an ordinary
/// port, not 5353, which makes it a "legacy unicast" query: devices answer
/// straight to that port, so no multicast lock is needed to hear them.
class MdnsSearch {
  MdnsSearch({
    InternetAddress? target,
    this.port = 5353,
    Future<List<InternetAddress>> Function()? localAddresses,
  }) : target = target ?? InternetAddress('224.0.0.251'),
       _localAddresses = localAddresses ?? privateAddresses;

  static const service = '_googlecast._tcp.local';

  final InternetAddress target;
  final int port;
  final Future<List<InternetAddress>> Function() _localAddresses;

  /// The devices as they answer, each once, until [timeout]; the question
  /// is sent [repeats] times, UDP can lose one.
  Stream<MdnsAnswer> search({
    Duration timeout = const Duration(seconds: 4),
    int repeats = 3,
  }) => multicastSearch(
    question: dnsQuery(service, DnsType.ptr),
    target: target,
    port: port,
    localAddresses: _localAddresses,
    read: (datagram, via) =>
        mdnsAnswers(datagram.data, from: datagram.address, via: via),
    key: (answer) => answer.instance,
    timeout: timeout,
    repeats: repeats,
  );
}

/// The Google Cast devices an mDNS message describes. A device answers
/// from its own address, which stands in for an A record it leaves out.
/// One that names an address off this network ([isLanTarget]), or port 0,
/// is no answer: the app would connect there and send it the episode.
List<MdnsAnswer> mdnsAnswers(
  Uint8List message, {
  required InternetAddress from,
  required InternetAddress via,
}) {
  final List<DnsRecord> records;
  try {
    records = dnsRecords(message);
  } on FormatException {
    return const [];
  }
  String lower(String s) => s.toLowerCase();
  final instances = {
    for (final r in records)
      if (r.type == DnsType.ptr &&
          lower(r.name) == MdnsSearch.service &&
          r.data is String)
        r.data! as String,
  };
  return [
    for (final instance in instances) ?_answer(records, instance, from, via),
  ];
}

MdnsAnswer? _answer(
  List<DnsRecord> records,
  String instance,
  InternetAddress from,
  InternetAddress via,
) {
  bool owns(DnsRecord r) => r.name.toLowerCase() == instance.toLowerCase();
  final srv = records
      .where((r) => owns(r) && r.type == DnsType.srv)
      .map((r) => r.data)
      .whereType<(int, String)>()
      .firstOrNull;
  final txt = records
      .where((r) => owns(r) && r.type == DnsType.txt)
      .map((r) => r.data)
      .whereType<Map<String, String>>()
      .firstOrNull;
  final target = srv?.$2.toLowerCase();
  final a = records
      .where((r) => r.type == DnsType.a && r.name.toLowerCase() == target)
      .map((r) => r.data)
      .whereType<Uint8List>()
      .firstOrNull;
  final address = a == null
      ? from
      : InternetAddress.fromRawAddress(a, type: InternetAddressType.IPv4);
  final port = srv?.$1 ?? 8009;
  if (port == 0 || !isLanTarget(address, from: from, via: via)) return null;
  return MdnsAnswer(
    instance: instance,
    address: address,
    port: port,
    txt: txt ?? const {},
    via: via,
  );
}
