import 'package:flutter/services.dart';

/// Android's Wi-Fi multicast lock: many phones drop multicast, and some the
/// answers to it, while their Wi-Fi saves power. Held while searching for
/// TVs; nothing elsewhere.
abstract final class MulticastLock {
  static const _channel = MethodChannel('tv_cast/network');

  /// Held from now; true when the system gave it.
  static Future<bool> hold() async {
    try {
      return await _channel.invokeMethod<bool>('lockMulticast') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> release() async {
    try {
      await _channel.invokeMethod<void>('unlockMulticast');
    } on MissingPluginException {
      // Nothing was held.
    } on PlatformException {
      // Let go of with the engine.
    }
  }
}
