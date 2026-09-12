import Darwin
import Foundation
import MirrorRelayProtocol
import Testing

private final class RelayTestBundle: NSObject {}

struct MirrorRelaySmokeTests {
  @Test func stdinEOFStopsTheHelper() throws {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    #expect(listener >= 0)
    defer { Darwin.close(listener) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    try #require(bound == 0)
    try #require(Darwin.listen(listener, 1) == 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
    }
    try #require(named == 0)

    let executable = Bundle(for: RelayTestBundle.self).bundleURL
      .deletingLastPathComponent().appendingPathComponent("prowl-mirror-relay")
    try #require(FileManager.default.isExecutableFile(atPath: executable.path))
    let process = Process()
    let input = Pipe()
    process.executableURL = executable
    process.arguments = [String(UInt16(bigEndian: address.sin_port)), "relay-test-token"]
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let ended = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in ended.signal() }
    try process.run()
    defer { if process.isRunning { process.terminate() } }
    var readiness = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
    try #require(Darwin.poll(&readiness, 1, 5000) > 0)
    let peer = Darwin.accept(listener, nil, nil)
    try #require(peer >= 0)
    defer { Darwin.close(peer) }
    try input.fileHandleForWriting.close()
    try #require(ended.wait(timeout: .now() + 5) == .success)
    #expect(process.terminationStatus == 0)
  }
}
