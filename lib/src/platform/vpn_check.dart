import 'dart:io';

import 'package:flutter/services.dart';

import '../vpn.dart';

/// Whether a VPN stands between this device and the TVs. Android says, and
/// tries the Wi-Fi around the VPN to tell a locked one; elsewhere the
/// adapters' names are the guess.
abstract final class VpnCheck {
  static const _channel = MethodChannel('tv_cast/network');

  static Future<VpnState> state() async {
    if (!Platform.isAndroid) return vpnByName();
    try {
      return switch (await _channel.invokeMethod<String>('vpnState')) {
        'locked' => VpnState.locked,
        'on' => VpnState.on,
        _ => VpnState.none,
      };
    } on MissingPluginException {
      return vpnByName();
    } on PlatformException {
      return vpnByName();
    }
  }
}
