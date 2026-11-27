/// iOS's DLNA search through the platform
/// (`lib/src/platform/native_ssdp.dart`): what
/// it asks the platform, what it makes of the answers, and a TV found end
/// to end from them. The platform is faked at its messenger, not through
/// the test binding, whose HTTP override would keep the fake TV's
/// description out of reach.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tv_cast/platform.dart';
import 'package:tv_cast/tv_cast.dart';

import 'dlna_test.dart' show FakeTv;

/// The platform's side of `tv_cast/network`: [reply] answers each call; no
/// plugin when it is null.
class FakePlatform extends BinaryMessenger {
  FakePlatform([this.reply]);

  final Object? Function(MethodCall call)? reply;
  final calls = <MethodCall>[];
  static const _codec = StandardMethodCodec();

  NativeSsdpSearch search() =>
      NativeSsdpSearch(channel: MethodChannel('tv_cast/network', _codec, this));

  @override
  Future<ByteData?>? send(String channel, ByteData? message) async {
    final call = _codec.decodeMethodCall(message);
    calls.add(call);
    final reply = this.reply;
    if (reply == null) return null;
    try {
      return _codec.encodeSuccessEnvelope(reply(call));
    } on PlatformException catch (e) {
      return _codec.encodeErrorEnvelope(code: e.code, message: e.message);
    }
  }

  @override
  Future<void> handlePlatformMessage(
    String channel,
    ByteData? data,
    PlatformMessageResponseCallback? callback,
  ) async {}

  @override
  void setMessageHandler(String channel, MessageHandler? handler) {}
}

String _answer(String location) =>
    'HTTP/1.1 200 OK\r\n'
    'LOCATION: $location\r\n'
    'SERVER: SHP, UPnP/1.0, Samsung UPnP SDK/1.0\r\n'
    'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
    'USN: uuid:0ad8e2c0-0000-1000-0000-tv::MediaRenderer\r\n\r\n';

void main() {
  test(
    'asks the platform for renderers, for as long as the search runs',
    () async {
      final platform = FakePlatform((_) => null);
      await platform
          .search()
          .search(timeout: const Duration(milliseconds: 2600))
          .toList();
      expect(platform.calls.single.method, 'ssdpSearch');
      expect(platform.calls.single.arguments, {
        'target': 'urn:schemas-upnp-org:device:MediaRenderer:1',
        'milliseconds': 2600,
      });
    },
  );

  test('each location once, from its sender, on the Wi-Fi address; what '
      "isn't an answer is left out", () async {
    final tv = _answer('http://192.168.1.5:7676/smp_11_');
    final platform = FakePlatform(
      (_) => {
        'via': '192.168.1.17',
        'answers': [
          {'from': '192.168.1.5', 'text': tv},
          // The second round's answer.
          {'from': '192.168.1.5', 'text': tv},
          {'from': '192.168.1.9', 'text': 'NOTIFY * HTTP/1.1\r\n\r\n'},
          {'from': '192.168.1.9', 'text': 'HTTP/1.1 200 OK\r\nST: x\r\n\r\n'},
          {'from': 'nowhere', 'text': _answer('http://192.168.1.6/')},
          'not an answer',
        ],
      },
    );
    final answers = await platform.search().search().toList();
    expect(answers, hasLength(1));
    final answer = answers.single;
    expect(answer.location, Uri.parse('http://192.168.1.5:7676/smp_11_'));
    expect(answer.from, InternetAddress('192.168.1.5'));
    expect(answer.via, InternetAddress('192.168.1.17'));
    expect(answer.server, 'SHP, UPnP/1.0, Samsung UPnP SDK/1.0');
  });

  test('none without the plugin (off iOS), off any Wi-Fi, or when the '
      'platform fails', () async {
    expect(await FakePlatform().search().search().toList(), isEmpty);
    expect(await FakePlatform((_) => null).search().search().toList(), isEmpty);
    expect(
      await FakePlatform(
        (_) => throw PlatformException(code: 'failed'),
      ).search().search().toList(),
      isEmpty,
    );
  });

  test("a TV found from the platform's answers, its description read as "
      "any search's", () async {
    final tv = FakeTv();
    await tv.start();
    addTearDown(tv.close);
    final platform = FakePlatform(
      (_) => {
        'via': '127.0.0.1',
        'answers': [
          {
            'from': '127.0.0.1',
            'text': _answer('http://127.0.0.1:${tv.httpPort}/smp_11_'),
          },
        ],
      },
    );
    final found = await DlnaDiscovery(
      search: platform.search(),
    ).find(timeout: const Duration(seconds: 1)).toList();
    expect(found.single.name, '[TV]Samsung LED49');
    expect(found.single.localAddress, InternetAddress.loopbackIPv4);
  });
}
