import Darwin
import Observation
import Testing

@testable import supacode

nonisolated enum MirrorTestPort {
  @MainActor
  static func startHost(_ host: MirrorHost) async throws {
    for attempt in 1...3 {
      host.start()
      for await done in Observations({ !host.isStarting || host.error != nil }) where done { break }
      if host.isRunning, host.error == nil { return }
      let occupied = MirrorConnectionFailure.addressInUse.listenerMessage(address: host.address, port: host.port)
      guard attempt < 3, host.error == occupied else {
        throw StartupFailure(reason: "Host startup failed at \(host.address):\(host.port): \(host.error ?? "unknown")")
      }
      // Port probing releases its socket before Network.framework binds. Retry
      // only that initial allocation race; reconnects must retain their port.
      host.port = String(try unusedPort())
    }
  }

  private struct StartupFailure: Error {
    let reason: String
  }

  static func unusedPort() throws -> UInt16 {
    let reservation = try boundPort()
    defer { Darwin.close(reservation.socket) }
    return reservation.port
  }

  static func withRefusedPort(_ body: (UInt16) async throws -> Void) async throws {
    let listener = try boundPort()
    defer { Darwin.close(listener.socket) }
    try #require(Darwin.listen(listener.socket, 1) == 0)
    let client = try boundPort()
    defer { Darwin.close(client.socket) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = listener.port.bigEndian
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(client.socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    try #require(result == 0)
    // A connected socket reserves its local port and refuses new connections.
    // A socket that is only bound can make connections time out on macOS.
    try await body(client.port)
  }

  private static func boundPort() throws -> (port: UInt16, socket: Int32) {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    try #require(descriptor >= 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        guard Darwin.bind(descriptor, $0, length) == 0 else { return Int32(-1) }
        return getsockname(descriptor, $0, &length)
      }
    }
    do {
      try #require(result == 0)
      return (UInt16(bigEndian: address.sin_port), descriptor)
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

}
