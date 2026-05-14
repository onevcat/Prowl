import Foundation
import Testing

@testable import supacode

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

@MainActor
struct CLISocketServerTests {
  @Test func secondServerDoesNotReplaceReachableSocket() throws {
    let socketPath = temporarySocketPath(suffix: "reachable-owner")
    let first = CLISocketServer(router: CLICommandRouter(), socketPath: socketPath)
    try first.start()
    defer { first.stop() }

    #expect(canConnect(to: socketPath))

    let second = CLISocketServer(router: CLICommandRouter(), socketPath: socketPath)
    #expect(throws: CLIServiceError.socketAlreadyOwned) {
      try second.start()
    }

    #expect(canConnect(to: socketPath))
  }

  @Test func ownerCanReplaceStaleSocketPath() throws {
    let socketPath = temporarySocketPath(suffix: "stale-owner")
    try createStaleSocket(at: socketPath)
    #expect(FileManager.default.fileExists(atPath: socketPath))
    #expect(!canConnect(to: socketPath))

    let server = CLISocketServer(router: CLICommandRouter(), socketPath: socketPath)
    try server.start()
    defer { server.stop() }

    #expect(canConnect(to: socketPath))
  }

  @Test func nonOwnerStopDoesNotRemoveOwnedSocketPath() throws {
    let socketPath = temporarySocketPath(suffix: "non-owner-stop")
    let first = CLISocketServer(router: CLICommandRouter(), socketPath: socketPath)
    try first.start()
    defer { first.stop() }

    let second = CLISocketServer(router: CLICommandRouter(), socketPath: socketPath)
    #expect(throws: CLIServiceError.socketAlreadyOwned) {
      try second.start()
    }
    second.stop()

    #expect(canConnect(to: socketPath))
  }

  @Test func ownedDescriptorsAreClosedOnExec() throws {
    let socketPath = temporarySocketPath(suffix: "cloexec")
    let server = CLISocketServer(router: CLICommandRouter(), socketPath: socketPath)
    try server.start()
    defer { server.stop() }

    let descriptors = server.debugFileDescriptors
    #expect(isCloseOnExec(descriptors.server))
    #expect(isCloseOnExec(descriptors.lock))
  }

  @Test func socketFilesAreOwnerOnly() throws {
    let socketPath = temporarySocketPath(suffix: "permissions")
    let socketDirectory = (socketPath as NSString).deletingLastPathComponent
    let lockPath = "\(socketPath).lock"
    let server = CLISocketServer(router: CLICommandRouter(), socketPath: socketPath)
    try server.start()
    defer { server.stop() }

    #expect(fileMode(at: socketDirectory) == 0o700)
    #expect(fileMode(at: socketPath) == 0o600)
    #expect(fileMode(at: lockPath) == 0o600)
  }

  @Test func peerUIDMustMatchCurrentUser() {
    #expect(CLISocketServer.isAllowedPeerUID(501, currentUID: 501))
    #expect(!CLISocketServer.isAllowedPeerUID(502, currentUID: 501))
  }

  @Test func acceptErrorClassificationKeepsRecoverableFailuresAlive() {
    #expect(CLISocketServer.shouldRetryAccept(after: EINTR))
    #expect(CLISocketServer.shouldRetryAccept(after: EMFILE))

    #expect(!CLISocketServer.shouldRetryAccept(after: EBADF))
    #expect(!CLISocketServer.shouldRetryAccept(after: EINVAL))
    #expect(!CLISocketServer.shouldRetryAccept(after: ENOTSOCK))
  }

  private func temporarySocketPath(suffix: String) -> String {
    URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appending(path: "prowl-cli-tests-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
      .appending(
        path: "prowl-\(suffix)-\(UUID().uuidString.prefix(8)).sock", directoryHint: .notDirectory
      )
      .path(percentEncoded: false)
  }

  private func fileMode(at path: String) -> mode_t? {
    var statValue = stat()
    guard stat(path, &statValue) == 0 else { return nil }
    return statValue.st_mode & mode_t(0o777)
  }

  private func createStaleSocket(at socketPath: String) throws {
    unlink(socketPath)
    try FileManager.default.createDirectory(
      atPath: (socketPath as NSString).deletingLastPathComponent,
      withIntermediateDirectories: true
    )
    let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketFD >= 0 else {
      throw CLIServiceError.socketCreationFailed
    }
    defer { close(socketFD) }
    try bindSocket(socketFD, to: socketPath)
  }

  private func canConnect(to socketPath: String) -> Bool {
    let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketFD >= 0 else { return false }
    defer { close(socketFD) }
    return withSocketAddress(socketPath) { address in
      withUnsafePointer(to: address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
          connect(socketFD, socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
    } == 0
  }

  private func bindSocket(_ socketFD: Int32, to socketPath: String) throws {
    let result = withSocketAddress(socketPath) { address in
      withUnsafePointer(to: address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
          bind(socketFD, socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
    }
    guard result == 0 else {
      throw CLIServiceError.bindFailed
    }
  }

  private func isCloseOnExec(_ fileDescriptor: Int32) -> Bool {
    let flags = fcntl(fileDescriptor, F_GETFD)
    return flags >= 0 && (flags & FD_CLOEXEC) == FD_CLOEXEC
  }

  private func withSocketAddress<Result>(
    _ socketPath: String, _ body: (sockaddr_un) throws -> Result
  ) rethrows
    -> Result
  {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    let maxLength = MemoryLayout.size(ofValue: address.sun_path) - 1
    precondition(pathBytes.count <= maxLength)
    let copyLength = min(pathBytes.count, maxLength)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      for index in 0..<copyLength {
        buffer[index] = pathBytes[index]
      }
      buffer[copyLength] = 0
    }
    return try body(address)
  }
}
