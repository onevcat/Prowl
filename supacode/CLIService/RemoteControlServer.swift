import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

nonisolated enum RemoteControlServerError: Error {
  case socketCreationFailed
  case socketConfigurationFailed
  case bindFailed
  case listenFailed
  case portResolutionFailed
  case clientRequestFailed
}

@MainActor
final class RemoteControlServer {
  nonisolated static let loopbackHost = "127.0.0.1"
  nonisolated static let port: UInt16 = 39466

  private nonisolated static let clientIOTimeout = timeval(tv_sec: 2, tv_usec: 0)
  private nonisolated static let clientDeadlineSeconds: Double = 5
  private nonisolated static let maximumHeaderByteCount = 16 * 1024

  private let router: RemoteControlRouter
  private let requestedPort: UInt16
  private let acceptQueue = DispatchQueue(label: "com.onevcat.prowl.remote-control-accept", qos: .userInitiated)
  private let clientQueue = DispatchQueue(
    label: "com.onevcat.prowl.remote-control-client",
    qos: .userInitiated,
    attributes: .concurrent
  )
  private let connections = RemoteControlConnectionRegistry()
  private var acceptSource: (any DispatchSourceRead)?
  private var serverFD: Int32 = -1

  private(set) var isRunning = false
  private(set) var boundPort: UInt16?

  init(router: RemoteControlRouter, port: UInt16 = RemoteControlServer.port) {
    self.router = router
    requestedPort = port
  }

  func start() throws {
    guard !isRunning else { return }
    serverFD = socket(AF_INET, SOCK_STREAM, 0)
    guard serverFD >= 0 else { throw RemoteControlServerError.socketCreationFailed }
    defer {
      if !isRunning, serverFD >= 0 {
        Darwin.close(serverFD)
        serverFD = -1
      }
    }

    try Self.configureListener(serverFD)
    var address = Self.loopbackAddress(port: requestedPort)
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
        bind(serverFD, socketPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else { throw RemoteControlServerError.bindFailed }
    guard listen(serverFD, 16) == 0 else { throw RemoteControlServerError.listenFailed }
    boundPort = try Self.resolveBoundPort(of: serverFD)

    let source = Self.makeAcceptSource(
      serverFD: serverFD,
      acceptQueue: acceptQueue,
      clientQueue: clientQueue,
      connections: connections,
      server: self
    )
    acceptSource = source
    isRunning = true
    source.resume()
  }

  func stop() {
    isRunning = false
    boundPort = nil
    connections.shutdownActive()
    if let acceptSource {
      self.acceptSource = nil
      acceptSource.cancel()
    }
    guard serverFD >= 0 else { return }
    let listeningFD = serverFD
    serverFD = -1
    // Closing on the serial accept queue after cancel() guarantees no in-flight accept still uses the
    // descriptor and that the listening port is released synchronously before stop() returns.
    acceptQueue.sync {
      _ = Darwin.close(listeningFD)
    }
  }

  private func response(for request: RemoteControlHTTPRequest) -> RemoteControlHTTPResponse {
    guard isRunning else {
      return .json(
        statusCode: 503,
        payload: RemoteControlServerErrorPayload(
          error: .init(code: "SERVICE_UNAVAILABLE", message: "Remote control is disabled.")
        )
      )
    }
    return router.route(request)
  }

  private nonisolated static func configureListener(_ fileDescriptor: Int32) throws {
    var reuseAddress: Int32 = 1
    guard
      setsockopt(fileDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, socklen_t(MemoryLayout<Int32>.size)) == 0
    else { throw RemoteControlServerError.socketConfigurationFailed }

    let descriptorFlags = fcntl(fileDescriptor, F_GETFD)
    guard descriptorFlags >= 0, fcntl(fileDescriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0
    else { throw RemoteControlServerError.socketConfigurationFailed }

    let statusFlags = fcntl(fileDescriptor, F_GETFL)
    guard statusFlags >= 0, fcntl(fileDescriptor, F_SETFL, statusFlags | O_NONBLOCK) == 0
    else { throw RemoteControlServerError.socketConfigurationFailed }
  }

  private nonisolated static func configureClient(_ fileDescriptor: Int32) throws {
    let descriptorFlags = fcntl(fileDescriptor, F_GETFD)
    guard descriptorFlags >= 0, fcntl(fileDescriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0
    else { throw RemoteControlServerError.socketConfigurationFailed }

    // Accepted sockets inherit O_NONBLOCK from the listener on Darwin; client I/O relies on blocking
    // reads and writes bounded by the socket timeouts below plus a connection-level deadline.
    let statusFlags = fcntl(fileDescriptor, F_GETFL)
    guard statusFlags >= 0, fcntl(fileDescriptor, F_SETFL, statusFlags & ~O_NONBLOCK) == 0
    else { throw RemoteControlServerError.socketConfigurationFailed }

    var noSigPipe: Int32 = 1
    guard setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0
    else { throw RemoteControlServerError.socketConfigurationFailed }

    var timeout = clientIOTimeout
    guard setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
      setsockopt(fileDescriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0
    else { throw RemoteControlServerError.socketConfigurationFailed }
  }

  private nonisolated static func loopbackAddress(port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
    return address
  }

  private nonisolated static func resolveBoundPort(of fileDescriptor: Int32) throws -> UInt16 {
    var address = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
        getsockname(fileDescriptor, socketPointer, &length)
      }
    }
    guard result == 0 else { throw RemoteControlServerError.portResolutionFailed }
    return UInt16(bigEndian: address.sin_port)
  }

  private nonisolated static func makeAcceptSource(
    serverFD: Int32,
    acceptQueue: DispatchQueue,
    clientQueue: DispatchQueue,
    connections: RemoteControlConnectionRegistry,
    server: RemoteControlServer?
  ) -> any DispatchSourceRead {
    let source = DispatchSource.makeReadSource(fileDescriptor: serverFD, queue: acceptQueue)
    source.setEventHandler { [weak server] in
      acceptPendingClients(serverFD: serverFD, server: server, connections: connections, clientQueue: clientQueue)
    }
    return source
  }

  private nonisolated static func acceptPendingClients(
    serverFD: Int32,
    server: RemoteControlServer?,
    connections: RemoteControlConnectionRegistry,
    clientQueue: DispatchQueue
  ) {
    while true {
      let clientFD = Darwin.accept(serverFD, nil, nil)
      guard clientFD >= 0 else {
        if errno == EINTR || errno == ECONNABORTED { continue }
        return
      }
      do {
        try configureClient(clientFD)
      } catch {
        Darwin.close(clientFD)
        continue
      }
      connections.register(clientFD)
      clientQueue.async { [weak server] in
        handleAcceptedClient(clientFD: clientFD, server: server, connections: connections, responseQueue: clientQueue)
      }
    }
  }

  private nonisolated static func handleAcceptedClient(
    clientFD: Int32,
    server: RemoteControlServer?,
    connections: RemoteControlConnectionRegistry,
    responseQueue: DispatchQueue
  ) {
    let request: RemoteControlHTTPRequest
    do {
      request = try readRequest(from: clientFD)
    } catch {
      try? write(
        .json(
          statusCode: 400,
          payload: RemoteControlServerErrorPayload(
            error: .init(code: "INVALID_REQUEST", message: "Malformed HTTP request.")
          )
        ),
        to: clientFD
      )
      connections.close(clientFD)
      return
    }

    Task { @MainActor [weak server] in
      let response =
        server?.response(for: request)
        ?? .json(
          statusCode: 503,
          payload: RemoteControlServerErrorPayload(
            error: .init(code: "SERVICE_UNAVAILABLE", message: "Remote control is unavailable.")
          )
        )
      responseQueue.async {
        try? Self.write(response, to: clientFD)
        connections.close(clientFD)
      }
    }
  }

  private nonisolated static func readRequest(from fileDescriptor: Int32) throws -> RemoteControlHTTPRequest {
    let terminator = Data([13, 10, 13, 10])
    let deadline = DispatchTime.now() + clientDeadlineSeconds
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while data.range(of: terminator) == nil {
      guard DispatchTime.now() < deadline else { throw RemoteControlServerError.clientRequestFailed }
      let count = buffer.withUnsafeMutableBytes { Darwin.read(fileDescriptor, $0.baseAddress, $0.count) }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { throw RemoteControlServerError.clientRequestFailed }
      data.append(contentsOf: buffer.prefix(Int(count)))
      guard data.count <= maximumHeaderByteCount else { throw RemoteControlServerError.clientRequestFailed }
    }

    guard let headerRange = data.range(of: terminator), headerRange.upperBound == data.endIndex,
      let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8)
    else { throw RemoteControlServerError.clientRequestFailed }

    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { throw RemoteControlServerError.clientRequestFailed }
    let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
    guard requestParts.count == 3, requestParts[2].hasPrefix("HTTP/"), requestParts[1].hasPrefix("/")
    else { throw RemoteControlServerError.clientRequestFailed }

    var headers: [String: String] = [:]
    for line in lines.dropFirst() where !line.isEmpty {
      guard let separator = line.firstIndex(of: ":") else { throw RemoteControlServerError.clientRequestFailed }
      let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty, headers[name] == nil else { throw RemoteControlServerError.clientRequestFailed }
      headers[name] = value
    }
    guard headers["transfer-encoding"] == nil, headers["content-length"].map({ $0 == "0" }) ?? true
    else { throw RemoteControlServerError.clientRequestFailed }
    return RemoteControlHTTPRequest(method: String(requestParts[0]), target: String(requestParts[1]), headers: headers)
  }

  private nonisolated static func write(_ response: RemoteControlHTTPResponse, to fileDescriptor: Int32) throws {
    var headers = response.headers
    headers["Connection"] = "close"
    headers["Content-Length"] = String(response.body.count)
    let headerText =
      (["HTTP/1.1 \(response.statusCode) \(statusReason(for: response.statusCode))"]
      + headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" } + ["", ""])
      .joined(separator: "\r\n")
    try write(Data(headerText.utf8), to: fileDescriptor)
    try write(response.body, to: fileDescriptor)
  }

  private nonisolated static func write(_ data: Data, to fileDescriptor: Int32) throws {
    let deadline = DispatchTime.now() + clientDeadlineSeconds
    try data.withUnsafeBytes { buffer in
      guard var baseAddress = buffer.baseAddress else { return }
      var remaining = buffer.count
      while remaining > 0 {
        guard DispatchTime.now() < deadline else { throw RemoteControlServerError.clientRequestFailed }
        let written = Darwin.write(fileDescriptor, baseAddress, remaining)
        if written < 0, errno == EINTR { continue }
        guard written > 0 else { throw RemoteControlServerError.clientRequestFailed }
        remaining -= written
        baseAddress = baseAddress.advanced(by: written)
      }
    }
  }

  private nonisolated static func statusReason(for statusCode: Int) -> String {
    switch statusCode {
    case 200: "OK"
    case 400: "Bad Request"
    case 401: "Unauthorized"
    case 404: "Not Found"
    case 405: "Method Not Allowed"
    case 503: "Service Unavailable"
    default: "Internal Server Error"
    }
  }
}

/// Tracks in-flight client sockets so shutdown can unblock them and closes happen exactly once.
nonisolated private final class RemoteControlConnectionRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var activeFileDescriptors: Set<Int32> = []

  func register(_ fileDescriptor: Int32) {
    lock.lock()
    defer { lock.unlock() }
    activeFileDescriptors.insert(fileDescriptor)
  }

  /// The registry is the sole owner of client socket closes, so descriptors are closed exactly once
  /// and never after their number has been reused elsewhere.
  func close(_ fileDescriptor: Int32) {
    lock.lock()
    defer { lock.unlock() }
    guard activeFileDescriptors.remove(fileDescriptor) != nil else { return }
    _ = Darwin.close(fileDescriptor)
  }

  /// Shuts down (but does not close) in-flight client sockets so blocked reads and writes return
  /// promptly; each handler still closes its own descriptor through `close(_:)`.
  func shutdownActive() {
    lock.lock()
    defer { lock.unlock() }
    for fileDescriptor in activeFileDescriptors {
      _ = Darwin.shutdown(fileDescriptor, SHUT_RDWR)
    }
  }
}

nonisolated private struct RemoteControlServerErrorPayload: Codable {
  let error: Error

  nonisolated struct Error: Codable {
    let code: String
    let message: String
  }
}
