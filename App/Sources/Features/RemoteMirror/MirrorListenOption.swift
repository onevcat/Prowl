import Foundation

/// One choice of the address that the Mirror listener binds to.
nonisolated struct MirrorListenOption: Identifiable, Equatable {
  let address: String
  let label: String
  var id: String { address }

  /// All interfaces, each IPv4 interface by name, this Mac only, and a saved value that is none of them.
  static func options(interfaces: [MirrorNetworkInterface], current: String) -> [MirrorListenOption] {
    var options = [
      MirrorListenOption(
        address: MirrorHostAddresses.allIPv4, label: String(localized: "All interfaces (0.0.0.0)"))
    ]
    for interface in interfaces where interface.isIPv4 && !interface.isLoopback {
      options.append(
        MirrorListenOption(address: interface.address, label: interface.label + " · " + interface.address))
    }
    options.append(
      MirrorListenOption(
        address: MirrorHostAddresses.loopback, label: String(localized: "This Mac only (127.0.0.1)"))
    )
    if !options.contains(where: { $0.address == current }) {
      options.append(MirrorListenOption(address: current, label: String(localized: "Custom · \(current)")))
    }
    return options
  }
}
