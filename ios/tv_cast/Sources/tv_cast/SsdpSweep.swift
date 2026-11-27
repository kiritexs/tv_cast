import Darwin
import Flutter
import Foundation

/// The DLNA search on iOS, for Dart's `NativeSsdpSearch`. iOS lets an app
/// multicast only with Apple's multicast entitlement, which a free account
/// can't have, but a question sent to one address needs nothing beyond the
/// Local Network permission. So the
/// M-SEARCH goes to the group (in case the app ever holds the entitlement)
/// and to every neighbour on the Wi-Fi directly, two rounds, as the SceneBox
/// app does. Native rather than Dart: Dart closes a socket at its first
/// refused send, and iOS refuses sends to a neighbour that didn't answer
/// lately ("host is down"); here a refused send is skipped.
enum SsdpSweep {
  private static let port: UInt16 = 1900
  private static let group = "239.255.255.250"
  /// More renderers than any home has: a host flooding the Wi-Fi can't grow
  /// what reaches Dart.
  private static let maxAnswers = 256

  struct Wifi {
    let address: String
    let prefixLength: Int
  }

  /// Searches on a background queue, then answers Dart on the main one:
  /// this device's address on the Wi-Fi and each answer's sender and text;
  /// nil off any Wi-Fi.
  static func run(arguments: Any?, result: @escaping FlutterResult) {
    let args = arguments as? [String: Any] ?? [:]
    let target = args["target"] as? String ?? "ssdp:all"
    let seconds = Double(args["milliseconds"] as? Int ?? 4000) / 1000
    DispatchQueue.global(qos: .userInitiated).async {
      let found = SsdpSweep.wifi().map { network -> [String: Any] in
        [
          "via": network.address,
          "answers": SsdpSweep.search(
            target: target,
            hosts: SsdpSweep.neighbours(
              of: network.address, prefixLength: network.prefixLength),
            duration: seconds),
        ]
      }
      DispatchQueue.main.async { result(found) }
    }
  }

  /// The Wi-Fi's address (en0), else another Ethernet-like link's or the
  /// Personal Hotspot's (bridge): never the cellular network's or a VPN's
  /// tunnel, nor a link-local one (no DHCP answer, no real network).
  static func wifi() -> Wifi? {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return nil }
    defer { freeifaddrs(head) }
    var found: [(name: String, wifi: Wifi)] = []
    var next = head
    while let entry = next?.pointee {
      next = entry.ifa_next
      guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
        let mask = entry.ifa_netmask
      else { continue }
      let flags = Int32(bitPattern: entry.ifa_flags)
      guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0
      else { continue }
      let name = String(cString: entry.ifa_name)
      guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
      var ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
        $0.pointee.sin_addr
      }
      let bits = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
        $0.pointee.sin_addr.s_addr
      }
      guard let text = string(&ip), !text.hasPrefix("169.254.") else { continue }
      found.append((name, Wifi(address: text, prefixLength: bits.nonzeroBitCount)))
    }
    return found.first(where: { $0.name == "en0" })?.wifi ?? found.first?.wifi
  }

  /// Every other address in [address]'s /24, or its whole subnet when that
  /// is smaller (a hotspot's): home networks are /24, and on a bigger one
  /// the TV is almost always this close.
  static func neighbours(of address: String, prefixLength: Int) -> [String] {
    var raw = in_addr()
    guard inet_pton(AF_INET, address, &raw) == 1 else { return [] }
    let ip = UInt32(bigEndian: raw.s_addr)
    let prefix = min(32, max(24, prefixLength))
    guard prefix < 31 else { return [] }
    let mask = ~(UInt32.max >> UInt32(prefix))
    let network = ip & mask
    let size = UInt32(1) << UInt32(32 - prefix)
    return (1..<(size - 1)).compactMap { offset in
      let host = network | offset
      guard host != ip else { return nil }
      return "\(host >> 24).\(host >> 16 & 255).\(host >> 8 & 255).\(host & 255)"
    }
  }

  /// Two rounds of the M-SEARCH, to the group and to each of [hosts] (UDP
  /// can lose one), then the answers heard within [duration], each once.
  static func search(target: String, hosts: [String], duration: TimeInterval)
    -> [[String: String]]
  {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { return [] }
    defer { close(fd) }
    var wait = timeval(tv_sec: 0, tv_usec: 150_000)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
    var ttl: UInt8 = 2
    setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

    // A refused send is skipped: the others go on.
    func send(to host: String) {
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = port.bigEndian
      guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return }
      let message = Array(question(host: host, target: target).utf8)
      _ = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          sendto(fd, message, message.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
    }

    var answers: [String: [String: String]] = [:]
    var buffer = [UInt8](repeating: 0, count: 4096)
    func collect(until deadline: Date) {
      while Date() < deadline {
        var from = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &from) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
          }
        }
        guard count > 0, let sender = string(&from.sin_addr) else { continue }
        // Past the cap the socket is still drained, so the rounds keep
        // their timing, but nothing more is kept.
        guard answers.count < maxAnswers else { continue }
        let text = String(decoding: buffer[0..<count], as: UTF8.self)
        // Only an answer (a 200 naming its description), once per sender
        // and location: the first wins.
        guard let location = answerLocation(in: text) else { continue }
        let key = sender + "\n" + location
        if answers[key] == nil { answers[key] = ["from": sender, "text": text] }
      }
    }

    let end = Date().addingTimeInterval(duration)
    for round in 0..<2 {
      send(to: group)
      for (index, host) in hosts.enumerated() {
        send(to: host)
        // Don't flood the Wi-Fi.
        if index % 32 == 31 { usleep(2000) }
      }
      collect(until: round == 0 ? Date().addingTimeInterval(duration / 2) : end)
    }
    return Array(answers.values)
  }

  /// [text]'s LOCATION when it is an SSDP answer (`HTTP/1.1 200`); nil
  /// otherwise. Dart's `readSsdpAnswer` still checks the rest.
  private static func answerLocation(in text: String) -> String? {
    let lines = text.components(separatedBy: "\n")
    guard let first = lines.first, first.uppercased().hasPrefix("HTTP/1.1 200") else {
      return nil
    }
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces)
      guard name.caseInsensitiveCompare("LOCATION") == .orderedSame else { continue }
      let value = line[line.index(after: colon)...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return value.isEmpty ? nil : value
    }
    return nil
  }

  /// The M-SEARCH, its HOST the group, or the device asked directly.
  private static func question(host: String, target: String) -> String {
    return "M-SEARCH * HTTP/1.1\r\n"
      + "HOST: \(host):\(port)\r\n"
      + "MAN: \"ssdp:discover\"\r\n"
      + "MX: 2\r\n"
      + "ST: \(target)\r\n\r\n"
  }

  private static func string(_ address: inout in_addr) -> String? {
    var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    guard inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN)) != nil else {
      return nil
    }
    return String(cString: text)
  }
}
