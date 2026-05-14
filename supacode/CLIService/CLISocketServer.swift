// supacode/CLIService/CLISocketServer.swift
// Unix domain socket server that listens for CLI command requests.

import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

@MainActor
final class CLISocketServer {
  nonisolated private static let acceptFailureBackoffSeconds: TimeInterval = 0.25

  private let router: CLICommandRouter
  private let socketPath: String
  private let lockPath: String
  private var serverFD: Int32 = -1
  private var lockFD: Int32 = -1
  private var ownsSocket = false
  private var isRunning = false
  private let acceptQueue = DispatchQueue(
    label: "com.onevcat.prowl.cli-accept", qos: .userInitiated)

  init(
    router: CLICommandRouter, socketPath: String = ProwlSocket.defaultPath, lockPath: String? = nil
  ) {
    self.router = router
    self.socketPath = socketPath
    self.lockPath = lockPath ?? "\(socketPath).lock"
  }

  /// Start listening for CLI connections.
  func start() throws {
    // Ensure parent directory exists (e.g. ~/Library/Application Support/com.onevcat.prowl)
    let parentDir = (socketPath as NSString).deletingLastPathComponent
    try ensureSocketDirectory(at: parentDir)

    var addr = try Self.socketAddress(for: socketPath)

    try acquireSocketLock()
    do {
      // A reachable socket belongs to an already-running app, including older
      // builds that do not hold the lock. Never unlink a live owner.
      guard !Self.canConnect(to: socketPath) else {
        throw CLIServiceError.socketAlreadyOwned
      }
    } catch {
      releaseSocketLock()
      throw error
    }

    // Clean up stale socket files only while holding the lock.
    unlink(socketPath)

    // Create socket
    serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard serverFD >= 0 else {
      releaseSocketLock()
      throw CLIServiceError.socketCreationFailed
    }
    do {
      try Self.setCloseOnExec(serverFD)
    } catch {
      close(serverFD)
      serverFD = -1
      releaseSocketLock()
      throw CLIServiceError.socketCreationFailed
    }

    // Bind
    let bindResult = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }

    guard bindResult == 0 else {
      close(serverFD)
      serverFD = -1
      releaseSocketLock()
      throw CLIServiceError.bindFailed
    }
    guard chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else {
      close(serverFD)
      serverFD = -1
      unlink(socketPath)
      releaseSocketLock()
      throw CLIServiceError.permissionFailed
    }

    // Listen
    guard listen(serverFD, 5) == 0 else {
      close(serverFD)
      serverFD = -1
      unlink(socketPath)
      releaseSocketLock()
      throw CLIServiceError.listenFailed
    }

    isRunning = true
    ownsSocket = true

    // Run the blocking accept loop on a dedicated dispatch queue so it does
    // not occupy a Swift cooperative-thread-pool thread (which would starve
    // the concurrency runtime and hang the app – especially during testing).
    let listeningFD = serverFD
    acceptQueue.async { [weak self] in
      Self.acceptLoop(serverFD: listeningFD, server: self)
    }
  }

  /// Stop the server and clean up.
  func stop() {
    isRunning = false
    if serverFD >= 0 {
      close(serverFD)
      serverFD = -1
    }
    if ownsSocket {
      unlink(socketPath)
      ownsSocket = false
    }
    releaseSocketLock()
  }

  private func acquireSocketLock() throws {
    guard lockFD < 0 else { return }
    lockFD = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard lockFD >= 0 else {
      throw CLIServiceError.lockFailed
    }
    guard fchmod(lockFD, S_IRUSR | S_IWUSR) == 0 else {
      releaseSocketLock()
      throw CLIServiceError.lockFailed
    }
    do {
      try Self.setCloseOnExec(lockFD)
    } catch {
      releaseSocketLock()
      throw CLIServiceError.lockFailed
    }
    guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
      releaseSocketLock()
      throw CLIServiceError.socketAlreadyOwned
    }
  }

  private func releaseSocketLock() {
    guard lockFD >= 0 else { return }
    flock(lockFD, LOCK_UN)
    close(lockFD)
    lockFD = -1
  }

  private func ensureSocketDirectory(at parentDir: String) throws {
    let fileManager = FileManager.default
    let existed = fileManager.fileExists(atPath: parentDir)
    try fileManager.createDirectory(
      atPath: parentDir,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )

    // Avoid chmod'ing arbitrary existing custom parents such as /tmp or $HOME
    // when PROWL_CLI_SOCKET is overridden.
    guard !existed || parentDir == Self.defaultSocketDirectory else { return }
    guard chmod(parentDir, S_IRWXU) == 0 else {
      throw CLIServiceError.permissionFailed
    }
  }

  // MARK: - Accept loop (runs on acceptQueue, NOT in Swift concurrency)

  private nonisolated static func acceptLoop(serverFD: Int32, server: CLISocketServer?) {
    let logger = SupaLogger("CLIService")
    while true {
      let clientFD = Darwin.accept(serverFD, nil, nil)
      if clientFD < 0 {
        let errorNumber = errno
        guard shouldRetryAccept(after: errorNumber) else {
          logger.info("CLI socket accept loop stopped: \(acceptErrorDescription(errorNumber))")
          return
        }
        if errorNumber != EINTR {
          logger.warning("CLI socket accept failed; retrying: \(acceptErrorDescription(errorNumber))")
          Thread.sleep(forTimeInterval: acceptFailureBackoffSeconds)
        }
        continue
      }
      guard let server else {
        Darwin.close(clientFD)
        return
      }

      Task { @MainActor in
        await server.handleClient(clientFD: clientFD)
      }
    }
  }

  nonisolated static func shouldRetryAccept(after errorNumber: Int32) -> Bool {
    switch errorNumber {
    case EINTR:
      true
    case EBADF, EINVAL, ENOTSOCK:
      false
    default:
      true
    }
  }

  private nonisolated static func acceptErrorDescription(_ errorNumber: Int32) -> String {
    let message = strerror(errorNumber).map { String(cString: $0) } ?? "Unknown error"
    return "errno=\(errorNumber) (\(message))"
  }

  private func handleClient(clientFD: Int32) async {
    defer { Darwin.close(clientFD) }

    do {
      guard Self.clientHasCurrentUser(clientFD) else { return }

      // Read length-prefixed request
      let lengthData = try Self.fdRead(fildes: clientFD, count: 4)
      let length = lengthData.withUnsafeBytes {
        UInt32(bigEndian: $0.load(as: UInt32.self))
      }
      guard length > 0, length < 10_000_000 else { return }

      let requestData = try Self.fdRead(fildes: clientFD, count: Int(length))

      // Decode envelope
      let decoder = JSONDecoder()
      let envelope = try decoder.decode(CommandEnvelope.self, from: requestData)

      // Route to handler
      let response = await router.route(envelope)

      // Encode and send response
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let responseData = try encoder.encode(response)

      var responseLength = UInt32(responseData.count).bigEndian
      try withUnsafeBytes(of: &responseLength) { try Self.fdWrite(fildes: clientFD, buffer: $0) }
      try responseData.withUnsafeBytes { try Self.fdWrite(fildes: clientFD, buffer: $0) }
    } catch {
      // Connection-level errors are silently dropped
    }
  }

  static func isAllowedPeerUID(_ peerUID: uid_t, currentUID: uid_t = geteuid()) -> Bool {
    peerUID == currentUID
  }

  private static func clientHasCurrentUser(_ clientFD: Int32) -> Bool {
    #if canImport(Darwin)
      var peerUID = uid_t()
      var peerGID = gid_t()
      guard getpeereid(clientFD, &peerUID, &peerGID) == 0 else {
        return false
      }
      return isAllowedPeerUID(peerUID)
    #else
      return true
    #endif
  }

  // MARK: - Low-level I/O using Darwin read/write

  private static func fdRead(fildes: Int32, count: Int) throws -> Data {
    var data = Data(capacity: count)
    var remaining = count
    let bufferSize = min(count, 65536)
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 1)
    defer { buffer.deallocate() }
    while remaining > 0 {
      let toRead = min(remaining, bufferSize)
      let bytesRead = Darwin.read(fildes, buffer, toRead)
      guard bytesRead > 0 else {
        throw CLIServiceError.readFailed
      }
      data.append(buffer.assumingMemoryBound(to: UInt8.self), count: bytesRead)
      remaining -= bytesRead
    }
    return data
  }

  private static func fdWrite(fildes: Int32, buffer: UnsafeRawBufferPointer) throws {
    var offset = 0
    while offset < buffer.count {
      let written = Darwin.write(
        fildes, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
      guard written > 0 else {
        throw CLIServiceError.writeFailed
      }
      offset += written
    }
  }

  private static func setCloseOnExec(_ fileDescriptor: Int32) throws {
    let flags = fcntl(fileDescriptor, F_GETFD)
    guard flags >= 0 else {
      throw CLIServiceError.closeOnExecFailed
    }
    guard fcntl(fileDescriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
      throw CLIServiceError.closeOnExecFailed
    }
  }

  private static func canConnect(to socketPath: String) -> Bool {
    let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketFD >= 0 else { return false }
    defer { close(socketFD) }

    guard let addr = try? socketAddress(for: socketPath) else {
      return false
    }
    let result = withUnsafePointer(to: addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        connect(socketFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    return result == 0
  }

  private static var defaultSocketDirectory: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library", directoryHint: .isDirectory)
      .appending(path: "Application Support", directoryHint: .isDirectory)
      .appending(path: "com.onevcat.prowl", directoryHint: .isDirectory)
      .path(percentEncoded: false)
  }

  private static func socketAddress(for socketPath: String) throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
    guard pathBytes.count <= maxLen else {
      throw CLIServiceError.socketPathTooLong
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { sunPathPtr in
      for idx in 0..<pathBytes.count {
        sunPathPtr[idx] = pathBytes[idx]
      }
      sunPathPtr[pathBytes.count] = 0
    }
    return addr
  }

  #if DEBUG
    var debugFileDescriptors: (server: Int32, lock: Int32) {
      (serverFD, lockFD)
    }
  #endif
}

// MARK: - Errors

enum CLIServiceError: Error, Equatable {
  case socketCreationFailed
  case socketPathTooLong
  case socketAlreadyOwned
  case lockFailed
  case closeOnExecFailed
  case permissionFailed
  case bindFailed
  case listenFailed
  case readFailed
  case writeFailed
}
