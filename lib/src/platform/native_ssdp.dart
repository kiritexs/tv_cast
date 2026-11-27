import 'dart:io';

import 'package:flutter/services.dart';

import '../dlna/ssdp.dart';

/// The DLNA search over iOS's own sockets: the M-SEARCH to the multicast
/// group and to every neighbour on the Wi-Fi directly, which iOS allows
/// without Apple's multicast entitlement. Native because Dart closes a
/// socket at its first refused send, and iOS refuses sends to a neighbour
/// that didn't answer lately. The answers come at the end, read here; none
/// off iOS or off any Wi-Fi.
class NativeSsdpSearch implements SsdpSearcher {
  NativeSsdpSearch({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('tv_cast/network');

  final MethodChannel _channel;

  @override
  Stream<SsdpAnswer> search({
    Duration timeout = const Duration(seconds: 4),
  }) async* {
    final Map<Object?, Object?>? found;
    try {
      found = await _channel.invokeMapMethod<Object?, Object?>('ssdpSearch', {
        'target': SsdpSearch.searchTarget,
        'milliseconds': timeout.inMilliseconds,
      });
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
    final via = InternetAddress.tryParse(found?['via'] as String? ?? '');
    if (found == null || via == null) return;
    final seen = <String>{};
    for (final raw in found['answers'] as List<Object?>? ?? const []) {
      if (raw is! Map) continue;
      final from = InternetAddress.tryParse(raw['from'] as String? ?? '');
      final text = raw['text'];
      if (from == null || text is! String) continue;
      final answer = readSsdpAnswer(text, from: from, via: via);
      if (answer != null && seen.add(answer.location.toString())) yield answer;
    }
  }
}
