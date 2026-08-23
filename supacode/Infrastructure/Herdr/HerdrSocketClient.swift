import Darwin
import Foundation

nonisolated internal enum HerdrSocketError: Error, Equatable, Sendable {
  case invalidSocketPath
  case socketCreationFailed(Int32)
  case socketConfigurationFailed(Int32)
  case connectionFailed(Int32)
  case writeFailed(Int32)
  case readFailed(Int32)
  case connectionClosed
  case responseTooLarge
  case invalidResponse
  case serverError(code: String, message: String)
  case unsupportedResponseType(String?)
  case unsupportedProtocol(supported: ClosedRange<UInt32>, actual: UInt32?)
}

nonisolated internal enum HerdrEventStreamState: Equatable, Sendable {
  case subscribed
  case event
  case disconnected(HerdrSocketError)
}

nonisolated internal struct HerdrSocketClient: Sendable {
  private static let maximumLineLength = 1_048_576
  fileprivate static let requestTimeout = timeval(tv_sec: 2, tv_usec: 0)
  private static let observedEventNames = [
    "workspace.focused",
    "tab.focused",
    "pane.focused",
    "pane.updated",
    "pane.agent_detected",
    "pane.exited",
    "pane.closed",
    "pane.moved",
  ]
  private static let terminalChromeEventNames = [
    "workspace.created",
    "workspace.updated",
    "workspace.renamed",
    "workspace.moved",
    "workspace.closed",
    "workspace.focused",
    "workspace.reordered",
    "tab.created",
    "tab.renamed",
    "tab.moved",
    "tab.closed",
    "tab.focused",
    "pane.created",
    "pane.updated",
    "pane.agent_detected",
    "pane.moved",
    "pane.focused",
    "pane.closed",
    "pane.exited",
    "layout.updated",
  ]

  internal let socketPath: String

  internal init(socketPath: String = HerdrSocketPathResolver.defaultPath()) {
    self.socketPath = socketPath
  }

  internal func currentPane(validateProtocol: Bool = true) async throws -> HerdrPaneInfo {
    let socketPath = socketPath
    return try await Task.detached(priority: .utility) {
      if validateProtocol {
        try Self.validateProtocol(at: socketPath)
      }
      let fileDescriptor = try Self.connect(to: socketPath)
      defer { Darwin.close(fileDescriptor) }
      try Self.setTimeout(Self.requestTimeout, on: fileDescriptor)
      let request = HerdrRequest(
        id: "prowl-clean-current",
        method: "pane.current",
        params: HerdrEmptyParams()
      )
      try Self.writeLine(try JSONEncoder().encode(request), to: fileDescriptor)
      let response = try Self.readResponse(from: fileDescriptor)
      guard let pane = response.currentPane else {
        throw HerdrSocketError.unsupportedResponseType(response.result?.type)
      }
      return pane
    }.value
  }

  internal func sessionSnapshot() async throws -> HerdrSessionSnapshot {
    let socketPath = socketPath
    return try await Task.detached(priority: .utility) {
      try Self.validateProtocol(at: socketPath)
      let fileDescriptor = try Self.connect(to: socketPath)
      defer { Darwin.close(fileDescriptor) }
      try Self.setTimeout(Self.requestTimeout, on: fileDescriptor)
      let request = HerdrRequest(
        id: "prowl-herdr-sidebar-snapshot",
        method: "session.snapshot",
        params: HerdrEmptyParams()
      )
      try Self.writeLine(try JSONEncoder().encode(request), to: fileDescriptor)
      return try Self.readSnapshotResponse(from: fileDescriptor)
    }.value
  }

  internal func focusWorkspace(_ workspaceID: String) async throws {
    try await performFocus(
      id: "prowl-herdr-sidebar-focus-workspace",
      method: "workspace.focus",
      params: HerdrWorkspaceFocusParams(workspaceID: workspaceID)
    )
  }

  internal func focusTab(_ tabID: String) async throws {
    try await performFocus(
      id: "prowl-herdr-sidebar-focus-tab",
      method: "tab.focus",
      params: HerdrTabFocusParams(tabID: tabID)
    )
  }

  internal func focusPane(_ paneID: String) async throws {
    try await performFocus(
      id: "prowl-herdr-sidebar-focus-pane",
      method: "pane.focus",
      params: HerdrPaneFocusParams(paneID: paneID)
    )
  }

  internal func createTab(workspaceID: String, label: String?) async throws {
    try await performRequest(
      id: "prowl-herdr-tab-create",
      method: "tab.create",
      params: HerdrTabCreateParams(workspaceID: workspaceID, focus: true, label: label)
    )
  }

  internal func renameTab(tabID: String, label: String) async throws {
    try await performRequest(
      id: "prowl-herdr-tab-rename",
      method: "tab.rename",
      params: HerdrTabRenameParams(tabID: tabID, label: label)
    )
  }

  internal func moveTab(tabID: String, insertIndex: Int) async throws {
    try await performRequest(
      id: "prowl-herdr-tab-move",
      method: "tab.move",
      params: HerdrTabMoveParams(tabID: tabID, insertIndex: insertIndex)
    )
  }

  internal func closeTab(tabID: String) async throws {
    try await performRequest(
      id: "prowl-herdr-tab-close",
      method: "tab.close",
      params: HerdrTabFocusParams(tabID: tabID)
    )
  }

  internal func closeWorkspace(workspaceID: String) async throws {
    try await performRequest(
      id: "prowl-herdr-workspace-close",
      method: "workspace.close",
      params: HerdrWorkspaceCloseParams(workspaceID: workspaceID)
    )
  }

  internal func events() -> AsyncStream<HerdrEventStreamState> {
    let socketPath = socketPath
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let session = HerdrEventSocketSession(
        socketPath: socketPath,
        eventNames: Self.observedEventNames,
        continuation: continuation
      )
      continuation.onTermination = { _ in
        session.cancel()
      }
      session.start()
    }
  }

  internal func terminalChromeEvents(paneIDs: Set<String>) -> AsyncStream<HerdrEventStreamState> {
    let socketPath = socketPath
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let session = HerdrEventSocketSession(
        socketPath: socketPath,
        eventNames: Self.terminalChromeEventNames,
        paneIDs: paneIDs,
        continuation: continuation
      )
      continuation.onTermination = { _ in
        session.cancel()
      }
      session.start()
    }
  }

  fileprivate static func connect(to socketPath: String) throws -> Int32 {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    let maximumPathLength = MemoryLayout.size(ofValue: address.sun_path) - 1
    guard !pathBytes.isEmpty, pathBytes.count <= maximumPathLength else {
      throw HerdrSocketError.invalidSocketPath
    }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
      destination.copyBytes(from: pathBytes)
      destination[pathBytes.count] = 0
    }

    let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fileDescriptor >= 0 else {
      throw HerdrSocketError.socketCreationFailed(errno)
    }
    var noSignal = Int32(1)
    let optionResult = withUnsafePointer(to: &noSignal) { value in
      setsockopt(
        fileDescriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        value,
        socklen_t(MemoryLayout<Int32>.size)
      )
    }
    guard optionResult == 0 else {
      let errorNumber = errno
      Darwin.close(fileDescriptor)
      throw HerdrSocketError.socketConfigurationFailed(errorNumber)
    }
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
        Darwin.connect(fileDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      let errorNumber = errno
      Darwin.close(fileDescriptor)
      throw HerdrSocketError.connectionFailed(errorNumber)
    }
    return fileDescriptor
  }

  fileprivate static func writeLine(_ data: Data, to fileDescriptor: Int32) throws {
    var payload = data
    payload.append(0x0A)
    try payload.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          fileDescriptor, baseAddress.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR {
          continue
        }
        guard count > 0 else {
          throw HerdrSocketError.writeFailed(errno)
        }
        offset += count
      }
    }
  }

  fileprivate static func readLine(from fileDescriptor: Int32) throws -> Data {
    var result = Data()
    var byte: UInt8 = 0
    while result.count < maximumLineLength {
      let count = Darwin.read(fileDescriptor, &byte, 1)
      if count < 0, errno == EINTR {
        continue
      }
      if count < 0 {
        throw HerdrSocketError.readFailed(errno)
      }
      guard count > 0 else {
        throw HerdrSocketError.connectionClosed
      }
      if byte == 0x0A {
        guard !result.isEmpty else { throw HerdrSocketError.invalidResponse }
        return result
      }
      result.append(byte)
    }
    throw HerdrSocketError.responseTooLarge
  }

  internal static func terminalChromeSubscriptionRequestData(paneIDs: Set<String>) throws -> Data {
    try subscriptionRequest(eventNames: terminalChromeEventNames, paneIDs: paneIDs)
  }

  fileprivate static func subscriptionRequest(
    eventNames: [String],
    paneIDs: Set<String> = []
  ) throws -> Data {
    let subscriptions = eventNames.map { HerdrEventsSubscribeParams.Subscription(type: $0) }
      + paneIDs.sorted().map {
        HerdrEventsSubscribeParams.Subscription(type: "pane.agent_status_changed", paneID: $0)
      }
    return try JSONEncoder().encode(
      HerdrRequest(
        id: "prowl-clean-events",
        method: "events.subscribe",
        params: HerdrEventsSubscribeParams(subscriptions: subscriptions)
      )
    )
  }

  fileprivate static func protocolRequest() throws -> Data {
    try JSONEncoder().encode(
      HerdrRequest(
        id: "prowl-clean-protocol",
        method: "ping",
        params: HerdrEmptyParams()
      )
    )
  }

  fileprivate static func validateProtocol(at socketPath: String) throws {
    let fileDescriptor = try connect(to: socketPath)
    defer { Darwin.close(fileDescriptor) }
    try setTimeout(requestTimeout, on: fileDescriptor)
    try writeLine(try protocolRequest(), to: fileDescriptor)
    try HerdrProtocolCompatibility.validate(readResponse(from: fileDescriptor))
  }

  fileprivate static func readResponse(from fileDescriptor: Int32) throws -> HerdrResponseEnvelope {
    let response = try JSONDecoder().decode(
      HerdrResponseEnvelope.self,
      from: readLine(from: fileDescriptor)
    )
    if let error = response.error {
      throw HerdrSocketError.serverError(code: error.code, message: error.message)
    }
    return response
  }

  private static func readSnapshotResponse(from fileDescriptor: Int32) throws -> HerdrSessionSnapshot {
    let line = try readLine(from: fileDescriptor)
    let envelope = try JSONDecoder().decode(HerdrResponseEnvelope.self, from: line)
    if let error = envelope.error {
      throw HerdrSocketError.serverError(code: error.code, message: error.message)
    }
    return try JSONDecoder().decode(HerdrSnapshotResponse.self, from: line).snapshot
  }

  private func performFocus<Params: Encodable & Sendable>(
    id: String,
    method: String,
    params: Params
  ) async throws {
    try await performRequest(id: id, method: method, params: params)
  }

  private func performRequest<Params: Encodable & Sendable>(
    id: String,
    method: String,
    params: Params
  ) async throws {
    let socketPath = socketPath
    try await Task.detached(priority: .utility) {
      try Self.validateProtocol(at: socketPath)
      let fileDescriptor = try Self.connect(to: socketPath)
      defer { Darwin.close(fileDescriptor) }
      try Self.setTimeout(Self.requestTimeout, on: fileDescriptor)
      let request = HerdrRequest(id: id, method: method, params: params)
      try Self.writeLine(try JSONEncoder().encode(request), to: fileDescriptor)
      let response = try Self.readResponse(from: fileDescriptor)
      guard response.result?.type != nil else {
        throw HerdrSocketError.unsupportedResponseType(nil)
      }
    }.value
  }

  fileprivate static func setTimeout(_ timeout: timeval, on fileDescriptor: Int32) throws {
    var timeout = timeout
    for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
      let result = withUnsafePointer(to: &timeout) { value in
        setsockopt(
          fileDescriptor,
          SOL_SOCKET,
          option,
          value,
          socklen_t(MemoryLayout<timeval>.size)
        )
      }
      guard result == 0 else {
        throw HerdrSocketError.socketConfigurationFailed(errno)
      }
    }
  }
}

nonisolated private final class HerdrEventSocketSession: @unchecked Sendable {
  private let socketPath: String
  private let eventNames: [String]
  private let paneIDs: Set<String>
  private let continuation: AsyncStream<HerdrEventStreamState>.Continuation
  private let lock = NSLock()
  private var fileDescriptor: Int32 = -1
  private var isCancelled = false

  fileprivate init(
    socketPath: String,
    eventNames: [String],
    paneIDs: Set<String> = [],
    continuation: AsyncStream<HerdrEventStreamState>.Continuation
  ) {
    self.socketPath = socketPath
    self.eventNames = eventNames
    self.paneIDs = paneIDs
    self.continuation = continuation
  }

  fileprivate func start() {
    DispatchQueue.global(qos: .utility).async { [self] in
      run()
    }
  }

  fileprivate func cancel() {
    lock.lock()
    isCancelled = true
    let descriptor = fileDescriptor
    fileDescriptor = -1
    lock.unlock()
    if descriptor >= 0 {
      _ = Darwin.shutdown(descriptor, SHUT_RDWR)
      Darwin.close(descriptor)
    }
  }

  private func run() {
    do {
      try HerdrSocketClient.validateProtocol(at: socketPath)
      let descriptor = try HerdrSocketClient.connect(to: socketPath)
      lock.lock()
      if isCancelled {
        lock.unlock()
        Darwin.close(descriptor)
        continuation.finish()
        return
      }
      fileDescriptor = descriptor
      lock.unlock()

      try HerdrSocketClient.setTimeout(HerdrSocketClient.requestTimeout, on: descriptor)
      try HerdrSocketClient.writeLine(
        try HerdrSocketClient.subscriptionRequest(eventNames: eventNames, paneIDs: paneIDs),
        to: descriptor
      )
      let acknowledgement = try HerdrSocketClient.readResponse(from: descriptor)
      guard acknowledgement.result?.type == "subscription_started" else {
        throw HerdrSocketError.unsupportedResponseType(acknowledgement.result?.type)
      }
      try HerdrSocketClient.setTimeout(timeval(tv_sec: 0, tv_usec: 0), on: descriptor)
      continuation.yield(.subscribed)

      while true {
        let line = try HerdrSocketClient.readLine(from: descriptor)
        _ = try JSONDecoder().decode(HerdrEventEnvelope.self, from: line)
        continuation.yield(.event)
      }
    } catch let error as HerdrSocketError {
      if !cancelled {
        continuation.yield(.disconnected(error))
      }
    } catch {
      if !cancelled {
        continuation.yield(.disconnected(.invalidResponse))
      }
    }
    cancel()
    continuation.finish()
  }

  private var cancelled: Bool {
    lock.withLock { isCancelled }
  }
}
