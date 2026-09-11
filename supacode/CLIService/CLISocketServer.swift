// supacode/CLIService/CLISocketServer.swift
// Unix domain socket server that listens for CLI command requests.

import Foundation
import ProwlCLIShared

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

private let cliSocketLogger = SupaLogger("CLISocketServer")

@MainActor
final class CLISocketServer {
  private static let maximumFrameLength = WorkflowSizeLimits.transportFrame

  private let router: CLICommandRouter
  private let socketPath: String
  private let lockPath: String
  private let onClientAccepted: (@Sendable () -> Void)?
  private let onPeerMonitorUnavailable: (@Sendable () -> Void)?
  private let onStatusChanged: (@MainActor (CLIServiceStatus) -> Void)?
  private let duplicatePeerDescriptor: @Sendable (Int32) -> Int32
  private var serverFD: Int32 = -1
  private var lockFD: Int32 = -1
  private var ownsSocket = false
  private var isRunning = false
  /// Listening, stopped, or why the last `start()` failed (docs-ai 063 D1).
  private(set) var status: CLIServiceStatus = .stopped {
    didSet {
      guard status != oldValue else { return }
      onStatusChanged?(status)
    }
  }
  private let acceptQueue = DispatchQueue(
    label: "com.onevcat.prowl.cli-accept", qos: .userInitiated)

  init(
    router: CLICommandRouter,
    socketPath: String = ProwlSocket.defaultPath,
    lockPath: String? = nil,
    onClientAccepted: (@Sendable () -> Void)? = nil,
    onPeerMonitorUnavailable: (@Sendable () -> Void)? = nil,
    onStatusChanged: (@MainActor (CLIServiceStatus) -> Void)? = nil,
    duplicatePeerDescriptor: @escaping @Sendable (Int32) -> Int32 = {
      fcntl($0, F_DUPFD_CLOEXEC, 0)
    }
  ) {
    self.router = router
    self.socketPath = socketPath
    self.lockPath = lockPath ?? "\(socketPath).lock"
    self.onClientAccepted = onClientAccepted
    self.onPeerMonitorUnavailable = onPeerMonitorUnavailable
    self.onStatusChanged = onStatusChanged
    self.duplicatePeerDescriptor = duplicatePeerDescriptor
  }

  /// Start listening for CLI connections; `status` records the outcome either way.
  func start() throws {
    do {
      try startListening()
      status = .listening(path: socketPath)
    } catch let error as CLIServiceError {
      status = .failed(error, path: socketPath)
      throw error
    }
  }

  private func startListening() throws {
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
    let onClientAccepted = onClientAccepted
    acceptQueue.async { [weak self] in
      Self.acceptLoop(
        serverFD: listeningFD,
        server: self,
        onClientAccepted: onClientAccepted
      )
    }
  }

  /// Stop the server and clean up.
  func stop() {
    isRunning = false
    status = .stopped
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
    do {
      try fileManager.createDirectory(
        atPath: parentDir,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      throw CLIServiceError.socketDirectoryUnavailable
    }

    // Avoid chmod'ing arbitrary existing custom parents such as /tmp or $HOME
    // when PROWL_CLI_SOCKET is overridden.
    guard !existed || parentDir == Self.defaultSocketDirectory else { return }
    guard chmod(parentDir, S_IRWXU) == 0 else {
      throw CLIServiceError.permissionFailed
    }
  }

  // MARK: - Accept loop (runs on acceptQueue, NOT in Swift concurrency)

  private nonisolated static func acceptLoop(
    serverFD: Int32,
    server: CLISocketServer?,
    onClientAccepted: (@Sendable () -> Void)?
  ) {
    while true {
      let clientFD = Darwin.accept(serverFD, nil, nil)
      guard clientFD >= 0 else {
        // serverFD was closed (stop() called) or an error occurred – exit.
        return
      }
      if let server {
        guard configureAcceptedClient(clientFD), clientHasCurrentUser(clientFD) else {
          Darwin.close(clientFD)
          continue
        }
        let callerProcessID = peerProcessID(clientFD)
        let context = CLICommandContext(
          callerProcessID: callerProcessID,
          callerProcessAncestry: callerProcessID.map {
            CallerPaneResolver.processAncestry(forCallerProcess: $0)
          } ?? []
        )
        onClientAccepted?()
        Task { @MainActor in
          await server.handleClient(clientFD: clientFD, context: context)
        }
      } else {
        Darwin.close(clientFD)
      }
    }
  }

  private func handleClient(clientFD: Int32, context: CLICommandContext) async {
    defer { Darwin.close(clientFD) }

    do {
      // Read length-prefixed request
      let lengthData = try Self.fdRead(fildes: clientFD, count: 4)
      let length = lengthData.withUnsafeBytes {
        UInt32(bigEndian: $0.load(as: UInt32.self))
      }
      guard length > 0, length <= Self.maximumFrameLength else { return }

      let requestData = try Self.fdRead(fildes: clientFD, count: Int(length))

      // Decode envelope
      let decoder = JSONDecoder()
      let envelope = try decoder.decode(CommandEnvelope.self, from: requestData)

      // Hidden native hooks are fire-and-forget: their caller identity was
      // frozen at accept time, so routing must survive the bounded client exit.
      let preservesRouteAfterDisconnect: Bool
      if case .agentsHook = envelope.command {
        preservesRouteAfterDisconnect = true
      } else {
        preservesRouteAfterDisconnect = false
      }
      let monitorDescriptor = duplicatePeerDescriptor(clientFD)
      guard monitorDescriptor >= 0 else {
        cliSocketLogger.warning("Failed to duplicate a CLI peer descriptor")
        onPeerMonitorUnavailable?()
        return
      }
      let routeTask = Task { @MainActor [router] in
        await router.route(envelope, context: context)
      }
      let monitor = CLIPeerDisconnectMonitor(ownedFileDescriptor: monitorDescriptor) {
        if !preservesRouteAfterDisconnect { routeTask.cancel() }
      }
      let response = await routeTask.value
      monitor.cancel()
      guard !monitor.didDisconnect else { return }

      // Encode and send response
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let responseData = try encoder.encode(response)
      guard responseData.count > 0, responseData.count <= Self.maximumFrameLength else { return }

      var responseLength = UInt32(responseData.count).bigEndian
      try withUnsafeBytes(of: &responseLength) { try Self.fdWrite(fildes: clientFD, buffer: $0) }
      try responseData.withUnsafeBytes { try Self.fdWrite(fildes: clientFD, buffer: $0) }
    } catch {
      // Connection-level errors are silently dropped
    }
  }

  nonisolated static func configureAcceptedClient(_ fileDescriptor: Int32) -> Bool {
    #if canImport(Darwin)
      var enabled: Int32 = 1
      let noSigPipe = withUnsafePointer(to: &enabled) {
        setsockopt(
          fileDescriptor,
          SOL_SOCKET,
          SO_NOSIGPIPE,
          $0,
          socklen_t(MemoryLayout<Int32>.size)
        )
      }
      guard noSigPipe == 0 else { return false }
    #endif
    return (try? setCloseOnExec(fileDescriptor)) != nil
  }

  nonisolated static func isAllowedPeerUID(_ peerUID: uid_t, currentUID: uid_t = geteuid()) -> Bool {
    peerUID == currentUID
  }

  /// PID of the peer process on a connected AF_UNIX socket, or nil when the
  /// kernel cannot report one.
  nonisolated static func peerProcessID(_ clientFD: Int32) -> pid_t? {
    #if canImport(Darwin)
      var pid: pid_t = 0
      var length = socklen_t(MemoryLayout<pid_t>.size)
      // SOL_LOCAL / LOCAL_PEERPID from <sys/un.h>.
      guard getsockopt(clientFD, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else {
        return nil
      }
      return pid
    #else
      return nil
    #endif
  }

  private nonisolated static func clientHasCurrentUser(_ clientFD: Int32) -> Bool {
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

  private nonisolated static func setCloseOnExec(_ fileDescriptor: Int32) throws {
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

/// Watches a fully-consumed request socket without consuming bytes. EOF or
/// unexpected post-frame input cancels the request task so long waits cannot
/// outlive their CLI process.
nonisolated final class CLIPeerDisconnectMonitor: @unchecked Sendable {
  private let fileDescriptor: Int32
  private let onDisconnect: @Sendable () -> Void
  private let source: DispatchSourceRead
  private let lock = NSLock()
  private var disconnected = false

  convenience init?(
    fileDescriptor: Int32,
    duplicateDescriptor: @Sendable (Int32) -> Int32 = { fcntl($0, F_DUPFD_CLOEXEC, 0) },
    onDisconnect: @escaping @Sendable () -> Void
  ) {
    let ownedFileDescriptor = duplicateDescriptor(fileDescriptor)
    guard ownedFileDescriptor >= 0 else { return nil }
    self.init(ownedFileDescriptor: ownedFileDescriptor, onDisconnect: onDisconnect)
  }

  init(ownedFileDescriptor: Int32, onDisconnect: @escaping @Sendable () -> Void) {
    let source = DispatchSource.makeReadSource(
      fileDescriptor: ownedFileDescriptor,
      queue: DispatchQueue.global(qos: .userInitiated)
    )
    fileDescriptor = ownedFileDescriptor
    self.onDisconnect = onDisconnect
    self.source = source
    source.setEventHandler { [weak self] in self?.inspect() }
    source.setCancelHandler { Darwin.close(ownedFileDescriptor) }
    source.activate()
  }

  deinit {
    cancel()
  }

  var didDisconnect: Bool {
    lock.withLock { disconnected }
  }

  func cancel() {
    source.cancel()
  }

  private func inspect() {
    var byte: UInt8 = 0
    let result = recv(fileDescriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
    guard result == 0 || result > 0 else { return }
    let shouldNotify = lock.withLock { () -> Bool in
      guard !disconnected else { return false }
      disconnected = true
      return true
    }
    guard shouldNotify else { return }
    onDisconnect()
    cancel()
  }
}

// MARK: - Errors

nonisolated enum CLIServiceError: Error, Equatable, Sendable {
  case socketDirectoryUnavailable
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
