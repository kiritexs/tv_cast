import 'dart:io';

/// Whether a VPN stands between this device and the TVs. A VPN that takes
/// the whole network hides the TVs from every app; most VPN apps have a
/// switch that leaves the local network out ("Bypass LAN"), the internet
/// staying on the VPN.
enum VpnState {
  /// No VPN this device can see.
  none,

  /// A VPN is on and may hide the TVs; whether it lets apps around it is
  /// unknown, or it does (Android) but the app doesn't go around it.
  on,

  /// A VPN is on that refuses apps the Wi-Fi (Android: one that doesn't
  /// allow bypassing). Only its own switch can let the TVs through.
  locked,
}

/// Whether [name] reads like a VPN's network adapter: `tun0` and `ppp0` on
/// Android, a tunnel's name on Windows (`neko-tun`, `Wintun`, `WireGuard`,
/// `Mullvad`, `NordLynx`). A guess, for a hint only.
bool looksLikeVpn(String name) => _vpnName.hasMatch(name);

final _vpnName = RegExp(
  r'tun|tap|vpn|ppp|ipsec|wireguard|\bwg|nordlynx|mullvad',
  caseSensitive: false,
);

/// A VPN by its adapter's name ([looksLikeVpn]): where the system can't
/// say (Windows).
Future<VpnState> vpnByName() async {
  try {
    final nics = await NetworkInterface.list(type: InternetAddressType.IPv4);
    return nics.any((nic) => looksLikeVpn(nic.name))
        ? VpnState.on
        : VpnState.none;
  } on Object {
    return VpnState.none;
  }
}
