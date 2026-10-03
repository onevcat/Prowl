import Darwin
import Foundation
import Network
import SystemConfiguration

nonisolated struct MirrorNetworkInterface: Equatable, Identifiable, Sendable {
  let name: String
  let displayName: String?
  let address: String
  let isIPv4: Bool
  let isLoopback: Bool

  var id: String { name + ":" + address }
  var label: String { displayName ?? name }
}

nonisolated enum MirrorHostAddresses {
  static let allIPv4 = "0.0.0.0"
  static let allIPv6 = "::"
  static let loopback = "127.0.0.1"

  /// Addresses of this Mac, IPv4 first, without link-local IPv6.
  static func current() -> [MirrorNetworkInterface] {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return [] }
    defer { freeifaddrs(list) }
    let names = displayNames()
    var result: [MirrorNetworkInterface] = []
    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let entry = pointer.pointee
      guard let sockaddr = entry.ifa_addr, entry.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
      let family = Int32(sockaddr.pointee.sa_family)
      guard family == AF_INET || family == AF_INET6 else { continue }
      var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let length =
        family == AF_INET ? socklen_t(MemoryLayout<sockaddr_in>.size) : socklen_t(MemoryLayout<sockaddr_in6>.size)
      guard getnameinfo(sockaddr, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
        continue
      }
      var address = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
      if let scope = address.firstIndex(of: "%") { address = String(address[..<scope]) }
      if family == AF_INET6, address.lowercased().hasPrefix("fe80:") { continue }
      let name = String(cString: entry.ifa_name)
      result.append(
        MirrorNetworkInterface(
          name: name, displayName: names[name], address: address, isIPv4: family == AF_INET,
          isLoopback: entry.ifa_flags & UInt32(IFF_LOOPBACK) != 0))
    }
    return presentable(result)
  }

  /// Keeps loopback, interfaces macOS names (Wi-Fi, Ethernet, Thunderbolt Bridge) and VPN tunnels.
  /// Unnamed virtual interfaces such as bridge100, awdl0 or anpi0 are not addresses a user would enter.
  static func presentable(_ interfaces: [MirrorNetworkInterface]) -> [MirrorNetworkInterface] {
    interfaces.compactMap { interface -> MirrorNetworkInterface? in
      if interface.isLoopback || interface.displayName != nil { return interface }
      guard interface.name.hasPrefix("utun") else { return nil }
      return MirrorNetworkInterface(
        name: interface.name, displayName: "VPN", address: interface.address,
        isIPv4: interface.isIPv4, isLoopback: false)
    }
    .sorted { lhs, rhs in
      if lhs.isIPv4 != rhs.isIPv4 { return lhs.isIPv4 }
      if lhs.isLoopback != rhs.isLoopback { return rhs.isLoopback }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
  }

  /// Addresses a Client can enter for a listener bound to `listenAddress`.
  static func reachable(listenAddress: String, interfaces: [MirrorNetworkInterface]) -> [MirrorNetworkInterface] {
    switch listenAddress {
    case allIPv4:
      return interfaces.filter { $0.isIPv4 && !$0.isLoopback }
    case allIPv6:
      return interfaces.filter { !$0.isLoopback }
    default:
      let matches = interfaces.filter { $0.address == listenAddress }
      if matches.isEmpty {
        return [
          MirrorNetworkInterface(
            name: listenAddress, displayName: nil, address: listenAddress,
            isIPv4: IPv4Address(listenAddress) != nil, isLoopback: IPv4Address(listenAddress)?.isLoopback == true)
        ]
      }
      return matches
    }
  }

  /// The Bonjour name other Macs on the same network can resolve, without a DNS lookup.
  static func localHostName() -> String? {
    guard let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty else { return nil }
    return name + ".local"
  }

  private static func displayNames() -> [String: String] {
    guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
    var names: [String: String] = [:]
    for interface in interfaces {
      guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
        let display = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
      else { continue }
      names[bsd] = display
    }
    return names
  }
}
