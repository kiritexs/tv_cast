import AVFoundation
import AVKit
import Flutter
import UIKit

/// AirPlay on iOS. Whether audio and video go to an AirPlay device now,
/// from the audio route, told to Dart on every route change; and the
/// system's route button as a platform view. The keep-alive has nothing to
/// hold on iOS: AirPlay's own audio session keeps the player. The DLNA
/// search, on `tv_cast/network` (`SsdpSweep`).
public class TvCastPlugin: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel
  private var network: FlutterMethodChannel?
  private var observer: NSObjectProtocol?

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "tv_cast/airplay",
      binaryMessenger: registrar.messenger())
    let instance = TvCastPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.register(AirPlayButtonFactory(), withId: "tv_cast/airplay_button")
    instance.observe()
    let network = FlutterMethodChannel(
      name: "tv_cast/network",
      binaryMessenger: registrar.messenger())
    network.setMethodCallHandler { call, result in
      if call.method == "ssdpSearch" {
        SsdpSweep.run(arguments: call.arguments, result: result)
      } else {
        // Android's multicast lock and VPN check: nothing here.
        result(FlutterMethodNotImplemented)
      }
    }
    instance.network = network
  }

  private func observe() {
    observer = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      self.channel.invokeMethod("changed", arguments: TvCastPlugin.state())
    }
  }

  /// The AirPlay output of the current route, if there is one.
  static func state() -> [String: Any] {
    let airPlay = AVAudioSession.sharedInstance().currentRoute.outputs.first {
      $0.portType == .airPlay
    }
    return ["active": airPlay != nil, "name": airPlay?.portName ?? ""]
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "current":
      result(TvCastPlugin.state())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    if let observer = observer {
      NotificationCenter.default.removeObserver(observer)
    }
    observer = nil
    network?.setMethodCallHandler(nil)
    network = nil
  }
}

/// Makes the AirPlay buttons Dart asks for.
class AirPlayButtonFactory: NSObject, FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return AirPlayButton(frame: frame, args: args as? [String: Any] ?? [:])
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

/// The system's route picker, video devices first, in the app's colours.
class AirPlayButton: NSObject, FlutterPlatformView {
  private let picker: AVRoutePickerView

  init(frame: CGRect, args: [String: Any]) {
    picker = AVRoutePickerView(frame: frame)
    picker.backgroundColor = .clear
    if #available(iOS 13.0, *) {
      picker.prioritizesVideoDevices = true
    }
    if let tint = args["tint"] as? Int {
      picker.tintColor = AirPlayButton.color(tint)
    }
    if let active = args["activeTint"] as? Int {
      picker.activeTintColor = AirPlayButton.color(active)
    }
    super.init()
  }

  func view() -> UIView {
    return picker
  }

  /// A Dart colour's ARGB value.
  static func color(_ argb: Int) -> UIColor {
    return UIColor(
      red: CGFloat((argb >> 16) & 0xFF) / 255,
      green: CGFloat((argb >> 8) & 0xFF) / 255,
      blue: CGFloat(argb & 0xFF) / 255,
      alpha: CGFloat((argb >> 24) & 0xFF) / 255)
  }
}
