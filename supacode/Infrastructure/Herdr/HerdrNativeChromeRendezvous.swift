import Darwin
import Foundation

private nonisolated let herdrNativeChromeLogger = SupaLogger("HerdrNativeChrome")

nonisolated internal struct HerdrNativeChromeBinding: Equatable, Sendable {
  internal let clientInstanceID: String
  internal let surfaceProof: String
  internal let socketPath: String

  internal var environment: [String: String] {
    [
      "PROWL_HERDR_NATIVE_CHROME": "1",
      "PROWL_HERDR_NATIVE_CHROME_SOCKET": socketPath,
      "PROWL_HERDR_NATIVE_CHROME_CLIENT_INSTANCE_ID": clientInstanceID,
      "PROWL_HERDR_NATIVE_CHROME_SURFACE_PROOF": surfaceProof,
    ]
  }
}

nonisolated internal enum HerdrNativeChromeTransportError: Error, Equatable, Sendable {
  case invalidFrameLength
  case connectionClosed
  case invalidClaim(String)
  case notConnected
  case socket(Int32)
}

nonisolated internal final class HerdrNativeChromeCoordinator: @unchecked Sendable {
  private let lock = NSLock()
  private var rendezvous: HerdrNativeChromeRendezvous?

  internal func prepareSurface() throws -> HerdrNativeChromeBinding {
    let next = try HerdrNativeChromeRendezvous()
    let previous = lock.withLock {
      let previous = rendezvous
      rendezvous = next
      return previous
    }
    previous?.stop()
    return next.binding
  }

  internal func probe() async -> HerdrNativeClaimResult {
    guard let rendezvous = lock.withLock({ rendezvous }) else {
      return .noContractClaim
    }
    return await rendezvous.probe()
  }

  internal func stopSurface() {
    let previous = lock.withLock {
      defer { rendezvous = nil }
      return rendezvous
    }
    previous?.stop()
  }
}

nonisolated internal final class HerdrNativeChromeRendezvous: @unchecked Sendable {
  internal static let contractVersion: UInt32 = 1
  internal static let maximumFrameSize = 2 * 1024 * 1024
  internal static let claimWindow = Duration.milliseconds(250)
  internal static let requiredCapabilities: Set<String> = [
    "activation_transaction",
    "aggregate_sync",
    "endpoint_fencing",
    "ime_context",
    "process_info",
  ]

  internal let binding: HerdrNativeChromeBinding

  private enum ClaimState {
    case aggregate
    case incompatible(String)
    case noContract
  }

  private let condition = NSCondition()
  private let writeLock = NSLock()
  private var listenerDescriptor: Int32 = -1
  private var connectionDescriptor: Int32 = -1
  private var claimState: ClaimState?
  private var stopped = false
  private var streamContinuation: AsyncStream<HerdrNativeStreamState>.Continuation?
  private let stream: AsyncStream<HerdrNativeStreamState>

  internal init(temporaryDirectory: URL = FileManager.default.temporaryDirectory) throws {
    let identifier = UUID().uuidString.lowercased()
    let socketPath =
      temporaryDirectory
      .appending(path: "prowl-herdr-\(identifier.prefix(12)).sock")
      .path(percentEncoded: false)
    binding = HerdrNativeChromeBinding(
      clientInstanceID: UUID().uuidString.lowercased(),
      surfaceProof: UUID().uuidString.lowercased(),
      socketPath: socketPath
    )

    var continuation: AsyncStream<HerdrNativeStreamState>.Continuation?
    stream = AsyncStream(bufferingPolicy: .bufferingNewest(256)) {
      continuation = $0
    }
    streamContinuation = continuation

    listenerDescriptor = try Self.makeListener(at: socketPath)
    startAccepting()
  }

  deinit {
    stop()
  }

  internal func probe() async -> HerdrNativeClaimResult {
    let state = await Task.detached(priority: .userInitiated) { [self] in
      waitForClaim()
    }.value
    switch state {
    case .aggregate:
      return .aggregate(
        HerdrNativeContractSession(
          clientInstanceID: binding.clientInstanceID,
          stream: stream,
          send: { [weak self] data in
            guard let self else { throw HerdrNativeChromeTransportError.notConnected }
            try writeFrame(data)
          },
          cancel: { [weak self] in self?.stop() }
        )
      )
    case .incompatible(let message):
      return .incompatible(message)
    case .noContract:
      return .noContractClaim
    }
  }

  internal func stop() {
    condition.lock()
    guard !stopped else {
      condition.unlock()
      return
    }
    stopped = true
    let listener = listenerDescriptor
    listenerDescriptor = -1
    let connection = connectionDescriptor
    connectionDescriptor = -1
    condition.broadcast()
    condition.unlock()

    if listener >= 0 {
      _ = Darwin.shutdown(listener, SHUT_RDWR)
      Darwin.close(listener)
    }
    if connection >= 0 {
      _ = Darwin.shutdown(connection, SHUT_RDWR)
      Darwin.close(connection)
    }
    streamContinuation?.finish()
    try? FileManager.default.removeItem(atPath: binding.socketPath)
  }

  private func waitForClaim() -> ClaimState {
    let deadline = Date().addingTimeInterval(0.25)
    condition.lock()
    defer { condition.unlock() }
    while claimState == nil, !stopped {
      if !condition.wait(until: deadline) { break }
    }
    if let claimState { return claimState }
    claimState = .noContract
    let listener = listenerDescriptor
    listenerDescriptor = -1
    if listener >= 0 {
      _ = Darwin.shutdown(listener, SHUT_RDWR)
      Darwin.close(listener)
    }
    return .noContract
  }

  private func startAccepting() {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      self?.acceptLoop()
    }
  }

  private func acceptLoop() {
    while true {
      condition.lock()
      let listener = listenerDescriptor
      let shouldStop = stopped || listener < 0
      condition.unlock()
      if shouldStop { return }

      let descriptor = Darwin.accept(listener, nil, nil)
      if descriptor < 0 {
        if errno == EINTR { continue }
        return
      }
      handleConnection(descriptor)
    }
  }

  private func handleConnection(_ descriptor: Int32) {
    do {
      try Self.setNoSigPipe(on: descriptor)
      try Self.setTimeout(timeval(tv_sec: 0, tv_usec: 250_000), on: descriptor)
      let claimData = try Self.readFrame(from: descriptor)
      let claim = try validateClaim(claimData, peerPID: Self.peerPID(descriptor))
      try Self.setTimeout(timeval(tv_sec: 0, tv_usec: 0), on: descriptor)

      condition.lock()
      if stopped || claimState.map({ if case .noContract = $0 { true } else { false } }) == true {
        condition.unlock()
        Darwin.close(descriptor)
        return
      }
      let listener = listenerDescriptor
      listenerDescriptor = -1
      if connectionDescriptor >= 0 {
        _ = Darwin.shutdown(connectionDescriptor, SHUT_RDWR)
        Darwin.close(connectionDescriptor)
      }
      connectionDescriptor = descriptor
      claimState = .aggregate
      condition.broadcast()
      condition.unlock()

      if listener >= 0 {
        _ = Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
      }
      herdrNativeChromeLogger.debug(
        "native contract bound client=\(claim.clientInstanceID) peer_pid=\(claim.payload.processID)"
      )
      readAggregateFrames(from: descriptor)
    } catch {
      Darwin.close(descriptor)
      condition.lock()
      var listener: Int32 = -1
      if claimState == nil {
        claimState = .incompatible(String(describing: error))
        listener = listenerDescriptor
        listenerDescriptor = -1
        condition.broadcast()
      } else if case .aggregate? = claimState {
        streamContinuation?.yield(.incompatible(String(describing: error)))
      }
      condition.unlock()
      if listener >= 0 {
        _ = Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
      }
    }
  }

  private func validateClaim(
    _ data: Data,
    peerPID: Int32?
  ) throws -> HerdrNativeChromeEnvelope<HerdrNativeContractReady> {
    let decoder = JSONDecoder()
    try Self.validateCoreEnvelopeKeys(in: data)
    let claim: HerdrNativeChromeEnvelope<HerdrNativeContractReady>
    do {
      claim = try decoder.decode(
        HerdrNativeChromeEnvelope<HerdrNativeContractReady>.self,
        from: data
      )
    } catch {
      throw HerdrNativeChromeTransportError.invalidClaim("The contract claim is malformed.")
    }
    guard claim.messageKind == "contract_ready" else {
      throw HerdrNativeChromeTransportError.invalidClaim("The first frame is not contract_ready.")
    }
    guard claim.contractVersion == Self.contractVersion else {
      throw HerdrNativeChromeTransportError.invalidClaim(
        "Unsupported native chrome contract version \(claim.contractVersion)."
      )
    }
    guard claim.clientInstanceID == binding.clientInstanceID,
      claim.payload.surfaceProof == binding.surfaceProof
    else {
      throw HerdrNativeChromeTransportError.invalidClaim("Client/surface binding proof failed.")
    }
    guard peerPID == claim.payload.processID else {
      throw HerdrNativeChromeTransportError.invalidClaim("Peer process proof failed.")
    }
    guard Self.requiredCapabilities.isSubset(of: claim.payload.capabilities.required) else {
      throw HerdrNativeChromeTransportError.invalidClaim(
        "Required contract capabilities are absent.")
    }
    return claim
  }

  private func readAggregateFrames(from descriptor: Int32) {
    do {
      while true {
        let data = try Self.readFrame(from: descriptor)
        try Self.validateCoreEnvelopeKeys(in: data)
        let envelope = try JSONDecoder().decode(
          HerdrNativeChromeEnvelope<HerdrNativeAggregatePayload>.self,
          from: data
        )
        guard envelope.contractVersion == Self.contractVersion,
          envelope.clientInstanceID == binding.clientInstanceID,
          [
            "aggregate_sync_begin", "endpoint_projection", "aggregate_sync_commit",
            "aggregate_state",
            "activation_started", "activation_phase_changed", "activation_committed",
            "activation_rolled_back",
            "activation_failed", "mutation_result", "process_info_result",
          ].contains(envelope.messageKind),
          let sequence = envelope.eventSequence,
          let projectionRevision = envelope.projectionRevision
        else {
          throw HerdrNativeChromeTransportError.invalidClaim(
            "Aggregate frame core envelope is invalid.")
        }
        streamContinuation?.yield(
          .frame(
            HerdrNativeAggregateFrame(
              messageKind: envelope.messageKind,
              sequence: sequence,
              projectionRevision: projectionRevision,
              activationEpoch: envelope.activationEpoch,
              requestID: envelope.requestID,
              mutationResult: envelope.payload.succeeded.map {
                HerdrNativeMutationResult(succeeded: $0, message: envelope.payload.message)
              },
              processInfoTarget: envelope.payload.endpointKey.flatMap { endpointKey in
                envelope.payload.processInfo.map {
                  HerdrPaneTarget(endpointKey: endpointKey, paneID: $0.paneID)
                }
              },
              processInfoFence: envelope.payload.endpointFence,
              processInfo: envelope.payload.processInfo,
              state: envelope.payload.state,
              syncCommitted: envelope.payload.syncCommitted
            )
          )
        )
      }
    } catch {
      condition.lock()
      if connectionDescriptor == descriptor {
        connectionDescriptor = -1
      }
      condition.unlock()
      Darwin.close(descriptor)
      let contractIncompatible: Bool
      switch error {
      case HerdrNativeChromeTransportError.connectionClosed,
        HerdrNativeChromeTransportError.socket:
        contractIncompatible = false
      default:
        contractIncompatible = true
      }
      streamContinuation?.yield(
        contractIncompatible ? .incompatible(String(describing: error)) : .disconnected
      )
      streamContinuation?.finish()
    }
  }

  private func writeFrame(_ data: Data) throws {
    guard !data.isEmpty, data.count <= Self.maximumFrameSize else {
      throw HerdrNativeChromeTransportError.invalidFrameLength
    }
    writeLock.lock()
    defer { writeLock.unlock() }
    condition.lock()
    let descriptor = connectionDescriptor
    condition.unlock()
    guard descriptor >= 0 else { throw HerdrNativeChromeTransportError.notConnected }
    var length = UInt32(data.count).bigEndian
    try withUnsafeBytes(of: &length) { try Self.writeAll(Data($0), to: descriptor) }
    try Self.writeAll(data, to: descriptor)
  }

  private static func makeListener(at path: String) throws -> Int32 {
    try? FileManager.default.removeItem(atPath: path)
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw HerdrNativeChromeTransportError.socket(errno) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1
    guard !pathBytes.isEmpty, pathBytes.count <= capacity else {
      Darwin.close(descriptor)
      throw HerdrNativeChromeTransportError.socket(ENAMETOOLONG)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { bytes in
      bytes.copyBytes(from: pathBytes)
      bytes[pathBytes.count] = 0
    }
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0, listen(descriptor, 4) == 0 else {
      let code = errno
      Darwin.close(descriptor)
      throw HerdrNativeChromeTransportError.socket(code)
    }
    guard chmod(path, S_IRUSR | S_IWUSR) == 0 else {
      let code = errno
      Darwin.close(descriptor)
      throw HerdrNativeChromeTransportError.socket(code)
    }
    return descriptor
  }

  internal static func validateCoreEnvelopeKeys(in data: Data) throws {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw HerdrNativeChromeTransportError.invalidClaim("The contract frame is not a JSON object.")
    }
    let requiredKeys = [
      "event_sequence",
      "projection_revision",
      "request_id",
      "activation_epoch",
    ]
    guard requiredKeys.allSatisfy(object.keys.contains) else {
      throw HerdrNativeChromeTransportError.invalidClaim(
        "The contract frame omits a nullable core envelope field."
      )
    }
  }

  private static func peerPID(_ descriptor: Int32) -> Int32? {
    var value: pid_t = 0
    var length = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &value, &length) == 0 else {
      return nil
    }
    return value
  }

  private static func setNoSigPipe(on descriptor: Int32) throws {
    var enabled: Int32 = 1
    guard
      withUnsafePointer(
        to: &enabled,
        {
          setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            $0,
            socklen_t(MemoryLayout<Int32>.size)
          )
        }) == 0
    else {
      throw HerdrNativeChromeTransportError.socket(errno)
    }
  }

  private static func setTimeout(_ timeout: timeval, on descriptor: Int32) throws {
    var timeout = timeout
    for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
      guard
        withUnsafePointer(
          to: &timeout,
          {
            setsockopt(
              descriptor,
              SOL_SOCKET,
              option,
              $0,
              socklen_t(MemoryLayout<timeval>.size)
            )
          }) == 0
      else {
        throw HerdrNativeChromeTransportError.socket(errno)
      }
    }
  }

  private static func readFrame(from descriptor: Int32) throws -> Data {
    let header = try readExact(4, from: descriptor)
    let length = header.withUnsafeBytes { rawBuffer in
      UInt32(bigEndian: rawBuffer.loadUnaligned(as: UInt32.self))
    }
    guard length > 0, length <= maximumFrameSize else {
      throw HerdrNativeChromeTransportError.invalidFrameLength
    }
    return try readExact(Int(length), from: descriptor)
  }

  private static func readExact(_ count: Int, from descriptor: Int32) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    while offset < count {
      let readCount = data.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), count - offset)
      }
      if readCount < 0, errno == EINTR { continue }
      guard readCount > 0 else {
        if readCount < 0 { throw HerdrNativeChromeTransportError.socket(errno) }
        throw HerdrNativeChromeTransportError.connectionClosed
      }
      offset += readCount
    }
    return data
  }

  private static func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let written = Darwin.write(
          descriptor,
          bytes.baseAddress!.advanced(by: offset),
          bytes.count - offset
        )
        if written < 0, errno == EINTR { continue }
        guard written > 0 else { throw HerdrNativeChromeTransportError.socket(errno) }
        offset += written
      }
    }
  }
}
