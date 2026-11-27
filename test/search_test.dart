/// Where a TV search goes out from (`lib/src/dlna/ssdp.dart`): this
/// device's private addresses, or any address when they can't be listed
/// (some Androids), and then the address that reaches the TV found; its
/// multicast pinned to that adapter, and a VPN told by its adapter's name
/// (`lib/src/vpn.dart`).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tv_cast/src/dlna/ssdp.dart';
import 'package:tv_cast/src/vpn.dart';

void main() {
  test('the private addresses when they can be listed', () async {
    final local = InternetAddress('192.168.1.5');
    expect(await searchAddresses(() async => [local]), [local]);
  });

  test('any address when the list fails or is empty', () async {
    expect(
      await searchAddresses(() async => throw const SocketException('no')),
      [InternetAddress.anyIPv4],
    );
    expect(await searchAddresses(() async => []), [InternetAddress.anyIPv4]);
    expect(isAnyAddress(InternetAddress.anyIPv4), isTrue);
    expect(isAnyAddress(InternetAddress('192.168.1.5')), isFalse);
  });

  test(
    'the address towards a host: the one a connection leaves from',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((s) => s.destroy());
      final port = server.port;
      expect(
        await addressTowards('127.0.0.1', port),
        InternetAddress.loopbackIPv4,
      );
      await server.close();
      expect(await addressTowards('127.0.0.1', port), isNull);
    },
  );

  test("a search's multicast is pinned to its adapter; nothing to pin "
      'for any address', () async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    pinMulticast(socket, InternetAddress.loopbackIPv4);
    pinMulticast(socket, InternetAddress.anyIPv4);
    socket.close();
  });

  test("a VPN by its adapter's name", () {
    for (final name in [
      'tun0',
      'ppp0',
      'neko-tun',
      'Wintun Userspace Tunnel',
      'WireGuard Tunnel',
      'wg0',
      'NordLynx',
      'Mullvad',
      'ProtonVPN',
    ]) {
      expect(looksLikeVpn(name), isTrue, reason: name);
    }
    for (final name in [
      'wlan0',
      'Wi-Fi',
      'Ethernet',
      'rmnet_data0',
      'ccmni1',
      'vEthernet (Default Switch)',
      'Local Area Connection* 2',
      'en0',
    ]) {
      expect(looksLikeVpn(name), isFalse, reason: name);
    }
  });
}
