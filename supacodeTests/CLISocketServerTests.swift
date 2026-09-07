import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

@MainActor
struct CLISocketServerTests {
  @Test func workflowPayloadEscapingFitsTheSocketFrame() async throws {
    let socketPath = temporarySocketPath(suffix: "workflow-large")
    let server = CLISocketServer(router: CLICommandRouter(), socketPath: socketPath)
    try server.start()
    defer { server.stop() }
    let request = try JSONEncoder().encode(
      CommandEnvelope(
        output: .json,
        command: .workflow(.init(action: .deliver, body: String(repeating: "\u{1}", count: WorkflowSizeLimits.payload)))
      ))
    #expect(request.count > 32 * 1024 * 1024)
    #expect(request.count <= WorkflowSizeLimits.transportFrame)
    let response: Data = try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(with: Result { try Self.send(requestData: request, socketPath: socketPath) })
      }
    }
    #expect(try JSONDecoder().decode(CommandResponse.self, from: response).command == "workflow")
  }

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

  @Test func statusFollowsStartAndStop() throws {
    let socketPath = temporarySocketPath(suffix: "status")
    var published: [CLIServiceStatus] = []
    let server = CLISocketServer(
      router: CLICommandRouter(), socketPath: socketPath, onStatusChanged: { published.append($0) })
    #expect(server.status == .stopped)

    try server.start()
    #expect(server.status == .listening(path: socketPath))

    server.stop()
    #expect(server.status == .stopped)
    #expect(published == [.listening(path: socketPath), .stopped])
  }

  @Test func statusReportsAnAlreadyOwnedSocket() throws {
    let socketPath = temporarySocketPath(suffix: "status-owned")
    let first = CLISocketServer(router: CLICommandRouter(), socketPath: socketPath)
    try first.start()
    defer { first.stop() }

    let second = CLISocketServer(router: CLICommandRouter(), socketPath: socketPath)
    #expect(throws: CLIServiceError.socketAlreadyOwned) {
      try second.start()
    }
    #expect(second.status == .failed(.socketAlreadyOwned, path: socketPath))
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

  // `debugFileDescriptors` exists only in Debug builds, and so does this test —
  // `make bench` compiles this target under the Release configuration.
  #if DEBUG
    @Test func ownedDescriptorsAreClosedOnExec() throws {
      let socketPath = temporarySocketPath(suffix: "cloexec")
      let server = CLISocketServer(router: CLICommandRouter(), socketPath: socketPath)
      try server.start()
      defer { server.stop() }

      let descriptors = server.debugFileDescriptors
      #expect(isCloseOnExec(descriptors.server))
      #expect(isCloseOnExec(descriptors.lock))
    }
  #endif

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

  @Test func descriptorDuplicationFailureRejectsConnectionBeforeRouting() async throws {
    let socketPath = temporarySocketPath(suffix: "monitor-dup-failure")
    let pane = CallerPane(worktreeID: "wt", surfaceID: UUID())
    var recordedSignal: AgentSignal?
    let handler = AgentSignalCommandHandler(
      resolveCaller: { _ in pane },
      recordSignal: { _, signal in
        recordedSignal = signal
        return .recorded(binding: .current)
      }
    )
    let accepted = DispatchSemaphore(value: 0)
    let closed = DispatchSemaphore(value: 0)
    let peerClosed = DisconnectObservation()
    let rejected = DisconnectObservation()
    let server = CLISocketServer(
      router: CLICommandRouter(agentsSignalHandler: handler),
      socketPath: socketPath,
      onClientAccepted: {
        accepted.signal()
        if closed.wait(timeout: .now() + 10) == .success {
          peerClosed.signal()
        }
      },
      onPeerMonitorUnavailable: { rejected.signal() },
      duplicatePeerDescriptor: { _ in -1 }
    )
    try server.start()
    defer { server.stop() }
    let requestData = try JSONEncoder().encode(
      CommandEnvelope(
        output: .json,
        command: .agentsSignal(AgentSignalInput(event: .turnEnded, detail: "must not route"))
      )
    )

    try await Task.detached {
      try Self.sendAndCloseAfterAcceptance(
        requestData: requestData,
        socketPath: socketPath,
        accepted: accepted,
        closed: closed
      )
    }.value
    let closedBeforeRouting = await Task.detached {
      peerClosed.wait(timeout: .now() + 10)
    }.value
    #expect(closedBeforeRouting)
    let connectionRejected = await Task.detached {
      rejected.wait(timeout: .now() + 10)
    }.value

    #expect(connectionRejected)
    #expect(recordedSignal == nil)
  }

  @Test func socketRoundTripThreadsKernelPeerPIDIntoAgentSignalHandler() async throws {
    let socketPath = temporarySocketPath(suffix: "signal-context")
    let pane = CallerPane(worktreeID: "wt", surfaceID: UUID())
    var recordedSignal: AgentSignal?
    let handler = AgentSignalCommandHandler(
      resolveCaller: { processID in
        #expect(processID == getpid())
        return pane
      },
      recordSignal: { caller, signal in
        #expect(caller == pane)
        recordedSignal = signal
        return .recorded(binding: .current)
      },
      now: { Date(timeIntervalSince1970: 1_000) }
    )
    let server = CLISocketServer(
      router: CLICommandRouter(agentsSignalHandler: handler),
      socketPath: socketPath
    )
    try server.start()
    defer { server.stop() }
    let envelope = CommandEnvelope(
      output: .json,
      command: .agentsSignal(AgentSignalInput(event: .turnEnded, detail: "socket result"))
    )

    let requestData = try JSONEncoder().encode(envelope)
    let responseData = try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(
          with: Result {
            try Self.send(requestData: requestData, socketPath: socketPath)
          }
        )
      }
    }
    let response = try JSONDecoder().decode(CommandResponse.self, from: responseData)

    #expect(response.ok)
    #expect(response.command == "agents.signal")
    #expect(recordedSignal?.kind == .turnEnded)
    #expect(recordedSignal?.detail == "socket result")
  }

  @Test func nativeHookRoundTripThreadsKernelPeerPIDWithoutExposingToken() async throws {
    let socketPath = temporarySocketPath(suffix: "hook-context")
    let pane = CallerPane(worktreeID: "wt", surfaceID: UUID())
    let input = AgentNativeHookInput(
      runtime: .codex,
      token: "private-token",
      signal: AgentNativeHookSignal(
        event: .turnEnded,
        nativeEvent: "agent-turn-complete",
        cwd: "/tmp/project",
        sessionID: "thread-1"
      )
    )
    var recordedInput: AgentNativeHookInput?
    let handler = AgentNativeHookCommandHandler(
      resolveCaller: { context in
        #expect(context.callerProcessID == getpid())
        #expect(context.callerProcessAncestry.first?.processID == getpid())
        return pane
      },
      recordHook: { caller, received in
        #expect(caller == pane)
        recordedInput = received
        return true
      }
    )
    let server = CLISocketServer(
      router: CLICommandRouter(agentsHookHandler: handler),
      socketPath: socketPath
    )
    try server.start()
    defer { server.stop() }
    let requestData = try JSONEncoder().encode(
      CommandEnvelope(output: .json, command: .agentsHook(input))
    )

    let responseData = try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(
          with: Result { try Self.send(requestData: requestData, socketPath: socketPath) }
        )
      }
    }
    let response = try JSONDecoder().decode(CommandResponse.self, from: responseData)

    #expect(response.ok)
    #expect(recordedInput == input)
    let responseText = try #require(String(bytes: responseData, encoding: .utf8))
    #expect(!responseText.contains(input.token))
  }

  @Test func nativeHookRoutesAfterPeerClosesBeforeMainActorHandling() async throws {
    let socketPath = temporarySocketPath(suffix: "hook-short-lived-peer")
    let routeRecorded = DisconnectObservation()
    let pane = CallerPane(worktreeID: "wt", surfaceID: UUID())
    let input = AgentNativeHookInput(
      runtime: .codex,
      token: "private-token",
      signal: AgentNativeHookSignal(
        event: .turnEnded,
        nativeEvent: "agent-turn-complete",
        cwd: "/tmp/project",
        sessionID: "thread-1"
      )
    )
    var recordedInput: AgentNativeHookInput?
    let handler = AgentNativeHookCommandHandler(
      resolveCaller: { context in
        #expect(context.callerProcessID == getpid())
        #expect(context.callerProcessAncestry.first?.processID == getpid())
        return pane
      },
      recordHook: { _, received in
        recordedInput = received
        routeRecorded.signal()
        return true
      }
    )
    let accepted = DispatchSemaphore(value: 0)
    let closed = DispatchSemaphore(value: 0)
    let peerClosed = DisconnectObservation()
    let server = CLISocketServer(
      router: CLICommandRouter(agentsHookHandler: handler),
      socketPath: socketPath,
      onClientAccepted: {
        accepted.signal()
        if closed.wait(timeout: .now() + 10) == .success {
          peerClosed.signal()
        }
      }
    )
    try server.start()
    defer { server.stop() }
    let requestData = try JSONEncoder().encode(
      CommandEnvelope(output: .json, command: .agentsHook(input))
    )
    let sendTask = Task.detached {
      try Self.sendAndCloseAfterAcceptance(
        requestData: requestData,
        socketPath: socketPath,
        accepted: accepted,
        closed: closed
      )
    }

    try await sendTask.value
    let closedBeforeRouting = await Task.detached {
      peerClosed.wait(timeout: .now() + 10)
    }.value
    #expect(closedBeforeRouting)
    let didRoute = await Task.detached {
      routeRecorded.wait(timeout: .now() + 10)
    }.value
    #expect(didRoute)
    #expect(recordedInput == input)
  }

  @Test func closingPeerCancelsInFlightWaitRequest() async throws {
    let socketPath = temporarySocketPath(suffix: "wait-peer-eof")
    let probe = CancellationProbe()
    let accepted = DispatchSemaphore(value: 0)
    let closed = DispatchSemaphore(value: 0)
    let peerClosed = DisconnectObservation()
    let server = CLISocketServer(
      router: CLICommandRouter(agentsWaitHandler: CancellationProbeHandler(probe: probe)),
      socketPath: socketPath,
      onClientAccepted: {
        accepted.signal()
        if closed.wait(timeout: .now() + 10) == .success {
          peerClosed.signal()
        }
      }
    )
    try server.start()
    defer { server.stop() }
    let envelope = CommandEnvelope(
      output: .json,
      command: .agentsWait(
        AgentWaitInput(mode: .dispatch, dispatchID: "dispatch-peer-eof", timeoutSeconds: 600)
      )
    )
    let requestData = try JSONEncoder().encode(envelope)

    try await Task.detached {
      try Self.sendAndCloseAfterAcceptance(
        requestData: requestData,
        socketPath: socketPath,
        accepted: accepted,
        closed: closed
      )
    }.value

    let closedBeforeRouting = await Task.detached {
      peerClosed.wait(timeout: .now() + 10)
    }.value
    #expect(closedBeforeRouting)
    let cancellationObserved = await Task.detached {
      probe.waitForCancellation(timeout: .now() + 10)
    }.value
    #expect(cancellationObserved)
    #expect(probe.wasCancelled)
  }

  #if canImport(Darwin)
    @Test func disconnectMonitorActivatesDuringCreation() async throws {
      var descriptors: [Int32] = [-1, -1]
      #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
      defer { close(descriptors[0]) }
      let observation = DisconnectObservation()
      let monitor = try #require(
        CLIPeerDisconnectMonitor(fileDescriptor: descriptors[0]) {
          observation.signal()
        }
      )

      close(descriptors[1])
      let activatedDuringCreation = await Task.detached {
        observation.wait(timeout: .now() + 1)
      }.value

      #expect(activatedDuringCreation)
      monitor.cancel()
    }

    @Test func disconnectMonitorOutlivesOriginalDescriptor() async throws {
      var descriptors: [Int32] = [-1, -1]
      #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
      let observation = DisconnectObservation()
      let monitor = try #require(
        CLIPeerDisconnectMonitor(fileDescriptor: descriptors[0]) {
          observation.signal()
        }
      )

      close(descriptors[0])
      close(descriptors[1])
      let disconnected = await Task.detached {
        observation.wait(timeout: .now() + 10)
      }.value

      #expect(disconnected)
      monitor.cancel()
    }

    @Test func acceptedSocketSuppressesSIGPIPEAndClosesOnExec() throws {
      var descriptors: [Int32] = [-1, -1]
      #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
      defer {
        close(descriptors[0])
        close(descriptors[1])
      }

      #expect(CLISocketServer.configureAcceptedClient(descriptors[0]))
      var enabled: Int32 = 0
      var length = socklen_t(MemoryLayout<Int32>.size)
      #expect(getsockopt(descriptors[0], SOL_SOCKET, SO_NOSIGPIPE, &enabled, &length) == 0)
      #expect(enabled == 1)
      #expect(fcntl(descriptors[0], F_GETFD) & FD_CLOEXEC != 0)
    }

    @Test func kernelReportsPeerPIDForLocalSocket() throws {
      var descriptors: [Int32] = [-1, -1]
      #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
      defer {
        close(descriptors[0])
        close(descriptors[1])
      }

      #expect(CLISocketServer.peerProcessID(descriptors[0]) == getpid())
    }
  #endif

  private func temporarySocketPath(suffix: String) -> String {
    URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appending(path: "prowl-cli-tests-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
      .appending(
        path: "prowl-\(suffix)-\(UUID().uuidString.prefix(8)).sock", directoryHint: .notDirectory
      )
      .path(percentEncoded: false)
  }

  nonisolated private static func send(requestData: Data, socketPath: String) throws -> Data {
    let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketFD >= 0 else { throw CLIServiceError.socketCreationFailed }
    defer { close(socketFD) }

    let connected = withSocketAddress(socketPath) { address in
      withUnsafePointer(to: address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
          connect(socketFD, socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
    }
    guard connected == 0 else { throw TestSocketClientError.connectFailed }

    var requestLength = UInt32(requestData.count).bigEndian
    try withUnsafeBytes(of: &requestLength) { try writeAll(socketFD, buffer: $0) }
    try requestData.withUnsafeBytes { try writeAll(socketFD, buffer: $0) }

    let lengthData = try readExact(socketFD, count: 4)
    let responseLength = lengthData.withUnsafeBytes { UInt32(bigEndian: $0.load(as: UInt32.self)) }
    return try readExact(socketFD, count: Int(responseLength))
  }

  nonisolated private static func sendAndCloseAfterAcceptance(
    requestData: Data,
    socketPath: String,
    accepted: DispatchSemaphore,
    closed: DispatchSemaphore
  ) throws {
    let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketFD >= 0 else { throw CLIServiceError.socketCreationFailed }
    defer {
      close(socketFD)
      closed.signal()
    }
    let connected = withSocketAddress(socketPath) { address in
      withUnsafePointer(to: address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
          connect(socketFD, socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
    }
    guard connected == 0 else { throw TestSocketClientError.connectFailed }

    var requestLength = UInt32(requestData.count).bigEndian
    try withUnsafeBytes(of: &requestLength) { try writeAll(socketFD, buffer: $0) }
    try requestData.withUnsafeBytes { try writeAll(socketFD, buffer: $0) }
    guard accepted.wait(timeout: .now() + 10) == .success else {
      throw CLIServiceError.readFailed
    }
  }

  nonisolated private static func writeAll(_ fileDescriptor: Int32, buffer: UnsafeRawBufferPointer) throws {
    var offset = 0
    while offset < buffer.count {
      let written = Darwin.write(
        fileDescriptor,
        buffer.baseAddress!.advanced(by: offset),
        buffer.count - offset
      )
      guard written > 0 else { throw CLIServiceError.writeFailed }
      offset += written
    }
  }

  nonisolated private static func readExact(_ fileDescriptor: Int32, count: Int) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    while offset < count {
      let readCount = data.withUnsafeMutableBytes { buffer in
        Darwin.read(fileDescriptor, buffer.baseAddress!.advanced(by: offset), count - offset)
      }
      guard readCount > 0 else { throw CLIServiceError.readFailed }
      offset += readCount
    }
    return data
  }

  nonisolated private static func withSocketAddress<Result>(
    _ socketPath: String,
    _ body: (sockaddr_un) throws -> Result
  ) rethrows -> Result {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    let maxLength = MemoryLayout.size(ofValue: address.sun_path) - 1
    precondition(pathBytes.count <= maxLength)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      for index in pathBytes.indices {
        buffer[index] = pathBytes[index]
      }
      buffer[pathBytes.count] = 0
    }
    return try body(address)
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

private nonisolated final class DisconnectObservation: @unchecked Sendable {
  private let semaphore = DispatchSemaphore(value: 0)

  func signal() {
    semaphore.signal()
  }

  func wait(timeout: DispatchTime) -> Bool {
    semaphore.wait(timeout: timeout) == .success
  }
}

private enum TestSocketClientError: Error {
  case connectFailed
}

private struct CancellationProbeHandler: CommandHandler {
  let probe: CancellationProbe

  func handle(envelope: CommandEnvelope) async -> CommandResponse {
    await probe.suspendUntilCancelled()
    return CommandResponse(
      ok: false,
      command: "agents.wait",
      schemaVersion: "prowl.cli.agents.wait.v1",
      error: CommandError(code: CLIErrorCode.timeout, message: "Cancelled.")
    )
  }
}

private nonisolated final class CancellationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let cancellationObserved = DispatchSemaphore(value: 0)
  private var cancellationContinuation: CheckedContinuation<Void, Never>?
  private var cancelled = false

  var wasCancelled: Bool {
    lock.withLock { cancelled }
  }

  func suspendUntilCancelled() async {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let resumeImmediately = lock.withLock { () -> Bool in
          guard !cancelled else { return true }
          cancellationContinuation = continuation
          return false
        }
        if resumeImmediately { continuation.resume() }
      }
    } onCancel: {
      markCancelled()
    }
  }

  nonisolated func waitForCancellation(timeout: DispatchTime) -> Bool {
    cancellationObserved.wait(timeout: timeout) == .success
  }

  private func markCancelled() {
    let continuation = lock.withLock {
      cancelled = true
      defer { cancellationContinuation = nil }
      return cancellationContinuation
    }
    cancellationObserved.signal()
    continuation?.resume()
  }
}
