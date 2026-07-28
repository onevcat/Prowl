import Foundation
import Testing

@testable import supacode

#if canImport(Darwin)
  import Darwin
#endif

@MainActor
struct RemoteControlServerTests {
  private let token = "server-test-token"
  private let paneID = UUID(uuidString: "1B9C6A34-27C4-4C39-8F0A-6C4C3E0F5A21")!

  @Test func halfOpenClientDoesNotBlockConcurrentValidRequests() async throws {
    let server = makeServer()
    try server.start()
    defer { server.stop() }
    let port = try #require(server.boundPort)

    let halfOpenFD = try connect(to: port)
    defer { Darwin.close(halfOpenFD) }

    let statusCode = try await requestAgentsStatusCode(port: port)
    #expect(statusCode == 200)
  }

  @Test func disableAndReEnableRecoverWhileAClientIsStalled() async throws {
    let server = makeServer()
    try server.start()
    let firstPort = try #require(server.boundPort)
    let stalledFD = try connect(to: firstPort)
    defer { Darwin.close(stalledFD) }
    send("GET /v1/agents HTTP/1.1\r\nauthorization: incomplete", on: stalledFD)

    server.stop()
    #expect(server.boundPort == nil)

    // The listening port must be released synchronously so re-enabling on the same fixed port works.
    let restartedServer = makeServer(port: firstPort)
    try restartedServer.start()
    defer { restartedServer.stop() }

    let statusCode = try await requestAgentsStatusCode(port: try #require(restartedServer.boundPort))
    #expect(statusCode == 200)
  }

  @Test func clientsDisconnectingBeforeResponsesDoNotTerminateTheServer() async throws {
    let server = makeServer()
    try server.start()
    defer { server.stop() }
    let port = try #require(server.boundPort)

    let malformedFD = try connect(to: port)
    send("NOT-AN-HTTP-REQUEST\r\n\r\n", on: malformedFD)
    abruptlyClose(malformedFD)

    let unauthorizedFD = try connect(to: port)
    send("GET /v1/agents HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", on: unauthorizedFD)
    abruptlyClose(unauthorizedFD)

    let authorizedFD = try connect(to: port)
    send("GET /v1/agents HTTP/1.1\r\nauthorization: Bearer \(token)\r\n\r\n", on: authorizedFD)
    abruptlyClose(authorizedFD)

    let statusCode = try await requestAgentsStatusCode(port: port)
    #expect(statusCode == 200)
  }

  private func makeServer(port: UInt16 = 0) -> RemoteControlServer {
    let router = RemoteControlRouter(
      accessTokenProvider: { self.token },
      agentsProvider: {
        [
          RemoteControlAgentSnapshot(
            paneID: self.paneID,
            type: "codex",
            name: "codex",
            status: "working",
            projectName: "Prowl",
            branchName: "relay/mobile-control",
            lastChangedAt: Date(timeIntervalSince1970: 0)
          )
        ]
      },
      viewportProvider: { _ in "ready" }
    )
    return RemoteControlServer(router: router, port: port)
  }

  private func requestAgentsStatusCode(port: UInt16) async throws -> Int {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/agents")!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 5
    let (_, response) = try await URLSession.shared.data(for: request)
    return (response as? HTTPURLResponse)?.statusCode ?? -1
  }

  private func connect(to port: UInt16) throws -> Int32 {
    let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
    try #require(fileDescriptor >= 0)
    var noSigPipe: Int32 = 1
    _ = setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
        Darwin.connect(fileDescriptor, socketPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    try #require(result == 0)
    return fileDescriptor
  }

  private func send(_ text: String, on fileDescriptor: Int32) {
    let bytes = Array(text.utf8)
    _ = bytes.withUnsafeBytes { Darwin.write(fileDescriptor, $0.baseAddress, $0.count) }
  }

  /// Closes with `SO_LINGER` zero so the peer observes an abrupt reset instead of a graceful close.
  private func abruptlyClose(_ fileDescriptor: Int32) {
    var lingerOption = linger(l_onoff: 1, l_linger: 0)
    _ = setsockopt(fileDescriptor, SOL_SOCKET, SO_LINGER, &lingerOption, socklen_t(MemoryLayout<linger>.size))
    Darwin.close(fileDescriptor)
  }
}
