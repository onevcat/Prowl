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
}

@MainActor
final class RemoteControlServer {
  nonisolated static let loopbackHost = "127.0.0.1"
  nonisolated static let port: UInt16 = 39466

  private let router: RemoteControlRouter
  private let acceptQueue = DispatchQueue(label: "com.onevcat.prowl.remote-control-accept", qos: .userInitiated)
  private var serverFD: Int32 = -1

  private(set) var isRunning = false

  init(router: RemoteControlRouter) {
    self.router = router
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

    try Self.configure(serverFD)
    var address = Self.loopbackAddress()
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
        bind(serverFD, socketPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else { throw RemoteControlServerError.bindFailed }
    guard listen(serverFD, 16) == 0 else { throw RemoteControlServerError.listenFailed }

    isRunning = true
    let listeningFD = serverFD
    acceptQueue.async { [weak self] in
      Self.acceptLoop(serverFD: listeningFD, server: self)
    }
  }

  func stop() {
    isRunning = false
    guard serverFD >= 0 else { return }
    Darwin.close(serverFD)
    serverFD = -1
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

  private nonisolated static func configure(_ fileDescriptor: Int32) throws {
    var reuseAddress: Int32 = 1
    guard setsockopt(fileDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, socklen_t(MemoryLayout<Int32>.size)) == 0
    else { throw RemoteControlServerError.socketConfigurationFailed }

    let flags = fcntl(fileDescriptor, F_GETFD)
    guard flags >= 0, fcntl(fileDescriptor, F_SETFD, flags | FD_CLOEXEC) == 0
    else { throw RemoteControlServerError.socketConfigurationFailed }

    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    guard setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
      setsockopt(fileDescriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0
    else { throw RemoteControlServerError.socketConfigurationFailed }
  }

  private nonisolated static func loopbackAddress() -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
    return address
  }

  private nonisolated static func acceptLoop(serverFD: Int32, server: RemoteControlServer?) {
    while true {
      let clientFD = Darwin.accept(serverFD, nil, nil)
      guard clientFD >= 0 else { return }
      handleAcceptedClient(clientFD: clientFD, server: server)
    }
  }

  private nonisolated static func handleAcceptedClient(clientFD: Int32, server: RemoteControlServer?) {
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
      Darwin.close(clientFD)
      return
    }

    Task { @MainActor [weak server] in
      defer { Darwin.close(clientFD) }
      let response =
        server?.response(for: request)
        ?? .json(
          statusCode: 503,
          payload: RemoteControlServerErrorPayload(
            error: .init(code: "SERVICE_UNAVAILABLE", message: "Remote control is unavailable.")
          )
        )
      try? Self.write(response, to: clientFD)
    }
  }

  private nonisolated static func readRequest(from fileDescriptor: Int32) throws -> RemoteControlHTTPRequest {
    let terminator = Data([13, 10, 13, 10])
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while data.range(of: terminator) == nil {
      let count = buffer.withUnsafeMutableBytes { Darwin.read(fileDescriptor, $0.baseAddress, $0.count) }
      guard count > 0 else { throw RemoteControlServerError.socketConfigurationFailed }
      data.append(contentsOf: buffer.prefix(Int(count)))
      guard data.count <= 16 * 1024 else { throw RemoteControlServerError.socketConfigurationFailed }
    }

    guard let headerRange = data.range(of: terminator), headerRange.upperBound == data.endIndex,
      let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8)
    else { throw RemoteControlServerError.socketConfigurationFailed }

    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { throw RemoteControlServerError.socketConfigurationFailed }
    let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
    guard requestParts.count == 3, requestParts[2].hasPrefix("HTTP/"), requestParts[1].hasPrefix("/")
    else { throw RemoteControlServerError.socketConfigurationFailed }

    var headers: [String: String] = [:]
    for line in lines.dropFirst() where !line.isEmpty {
      guard let separator = line.firstIndex(of: ":") else { throw RemoteControlServerError.socketConfigurationFailed }
      let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty, headers[name] == nil else { throw RemoteControlServerError.socketConfigurationFailed }
      headers[name] = value
    }
    guard headers["transfer-encoding"] == nil, headers["content-length"].map({ $0 == "0" }) ?? true
    else { throw RemoteControlServerError.socketConfigurationFailed }
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
    try data.withUnsafeBytes { buffer in
      guard var baseAddress = buffer.baseAddress else { return }
      var remaining = buffer.count
      while remaining > 0 {
        let written = Darwin.write(fileDescriptor, baseAddress, remaining)
        guard written > 0 else { throw RemoteControlServerError.socketConfigurationFailed }
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

nonisolated private struct RemoteControlServerErrorPayload: Codable {
  let error: Error

  nonisolated struct Error: Codable {
    let code: String
    let message: String
  }
}
