import Darwin
import Testing

nonisolated enum MirrorTestPort {
  static func unusedPort() throws -> UInt16 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    try #require(descriptor >= 0)
    defer { Darwin.close(descriptor) }
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
    try #require(result == 0)
    return UInt16(bigEndian: address.sin_port)
  }

}
