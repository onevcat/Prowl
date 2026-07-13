import Foundation

nonisolated struct RemoteControlHTTPRequest: Sendable {
  let method: String
  let target: String
  let headers: [String: String]

  init(method: String, target: String, headers: [String: String] = [:]) {
    self.method = method.uppercased()
    self.target = target
    var normalizedHeaders: [String: String] = [:]
    for (name, value) in headers {
      normalizedHeaders[name.lowercased()] = value
    }
    self.headers = normalizedHeaders
  }
}

nonisolated struct RemoteControlHTTPResponse: Sendable {
  let statusCode: Int
  let headers: [String: String]
  let body: Data

  nonisolated static func json<T: Encodable>(
    statusCode: Int,
    payload: T,
    headers: [String: String] = [:]
  ) -> Self {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let body = (try? encoder.encode(payload)) ?? Data()
    var responseHeaders = [
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8",
      "X-Content-Type-Options": "nosniff",
    ]
    responseHeaders.merge(headers, uniquingKeysWith: { _, new in new })
    return Self(statusCode: statusCode, headers: responseHeaders, body: body)
  }
}

nonisolated struct RemoteControlAgentSnapshot: Sendable {
  let paneID: UUID
  let type: String
  let name: String
  let status: String
  let projectName: String
  let branchName: String
  let lastChangedAt: Date
}

@MainActor
final class RemoteControlRouter {
  typealias AccessTokenProvider = @MainActor () throws -> String
  typealias AgentsProvider = @MainActor () -> [RemoteControlAgentSnapshot]
  typealias ViewportProvider = @MainActor (UUID) -> String?

  static let maximumLineCount = 80
  static let maximumTextByteCount = 12 * 1024

  private let accessTokenProvider: AccessTokenProvider
  private let agentsProvider: AgentsProvider
  private let viewportProvider: ViewportProvider
  private let dateFormatter: ISO8601DateFormatter
  private var opaqueIDByPaneID: [UUID: String] = [:]
  private var paneIDByOpaqueID: [String: UUID] = [:]

  init(
    accessTokenProvider: @escaping AccessTokenProvider,
    agentsProvider: @escaping AgentsProvider,
    viewportProvider: @escaping ViewportProvider
  ) {
    self.accessTokenProvider = accessTokenProvider
    self.agentsProvider = agentsProvider
    self.viewportProvider = viewportProvider
    dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withInternetDateTime]
    dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
  }

  func route(_ request: RemoteControlHTTPRequest) -> RemoteControlHTTPResponse {
    guard authorize(request) else {
      return errorResponse(
        statusCode: 401,
        code: "UNAUTHORIZED",
        message: "A valid bearer token is required.",
        headers: ["WWW-Authenticate": "Bearer"]
      )
    }
    guard let components = URLComponents(string: "http://localhost\(request.target)") else {
      return errorResponse(statusCode: 400, code: "INVALID_REQUEST", message: "Invalid request target.")
    }
    if components.path == "/v1/agents" {
      guard request.method == "GET" else { return methodNotAllowed() }
      guard components.queryItems?.isEmpty != false else {
        return errorResponse(
          statusCode: 400, code: "INVALID_REQUEST", message: "This endpoint has no query parameters.")
      }
      return agentsResponse()
    }

    let pathComponents = components.path.split(separator: "/", omittingEmptySubsequences: true)
    guard pathComponents.count == 4,
      pathComponents[0] == "v1",
      pathComponents[1] == "agents",
      pathComponents[3] == "read"
    else {
      return errorResponse(statusCode: 404, code: "NOT_FOUND", message: "Endpoint not found.")
    }
    guard request.method == "GET" else { return methodNotAllowed() }
    return readResponse(opaqueID: String(pathComponents[2]), queryItems: components.queryItems ?? [])
  }

  private func authorize(_ request: RemoteControlHTTPRequest) -> Bool {
    guard let authorization = request.headers["authorization"],
      let accessToken = try? accessTokenProvider()
    else { return false }
    return constantTimeEqual(authorization, "Bearer \(accessToken)")
  }

  private func agentsResponse() -> RemoteControlHTTPResponse {
    let snapshots = agentsProvider()
    refreshOpaqueIDs(for: snapshots)
    let agents = snapshots.map { snapshot in
      RemoteControlAgent(
        id: opaqueIDByPaneID[snapshot.paneID] ?? "",
        type: snapshot.type,
        name: snapshot.name,
        status: snapshot.status,
        project: .init(name: snapshot.projectName, branch: snapshot.branchName),
        lastChangedAt: dateFormatter.string(from: snapshot.lastChangedAt)
      )
    }
    return .json(statusCode: 200, payload: RemoteControlAgentsPayload(count: agents.count, agents: agents))
  }

  private func readResponse(opaqueID: String, queryItems: [URLQueryItem]) -> RemoteControlHTTPResponse {
    guard queryItems.allSatisfy({ $0.name == "last" }), queryItems.count <= 1 else {
      return errorResponse(statusCode: 400, code: "INVALID_REQUEST", message: "Only one 'last' parameter is allowed.")
    }
    let requestedLineCount: Int
    if let rawLineCount = queryItems.first?.value {
      guard let lineCount = Int(rawLineCount), (1...Self.maximumLineCount).contains(lineCount) else {
        return errorResponse(
          statusCode: 400,
          code: "INVALID_REQUEST",
          message: "'last' must be between 1 and \(Self.maximumLineCount)."
        )
      }
      requestedLineCount = lineCount
    } else {
      requestedLineCount = Self.maximumLineCount
    }

    guard let paneID = paneIDByOpaqueID[opaqueID], let viewport = viewportProvider(paneID) else {
      return errorResponse(statusCode: 404, code: "TARGET_NOT_FOUND", message: "Agent target not found.")
    }
    let result = limit(viewport, maximumLines: requestedLineCount, maximumBytes: Self.maximumTextByteCount)
    return .json(
      statusCode: 200,
      payload: RemoteControlReadPayload(
        agentID: opaqueID,
        source: "viewport",
        lineCount: lineCount(in: result.text),
        text: result.text,
        truncated: result.truncated
      )
    )
  }

  private func refreshOpaqueIDs(for snapshots: [RemoteControlAgentSnapshot]) {
    let activePaneIDs = Set(snapshots.map(\.paneID))
    for paneID in opaqueIDByPaneID.keys.filter({ !activePaneIDs.contains($0) }) {
      guard let opaqueID = opaqueIDByPaneID.removeValue(forKey: paneID) else { continue }
      paneIDByOpaqueID.removeValue(forKey: opaqueID)
    }
    for paneID in activePaneIDs where opaqueIDByPaneID[paneID] == nil {
      let opaqueID = UUID().uuidString.lowercased()
      opaqueIDByPaneID[paneID] = opaqueID
      paneIDByOpaqueID[opaqueID] = paneID
    }
  }

  private func methodNotAllowed() -> RemoteControlHTTPResponse {
    errorResponse(
      statusCode: 405,
      code: "METHOD_NOT_ALLOWED",
      message: "This endpoint only accepts GET requests.",
      headers: ["Allow": "GET"]
    )
  }

  private func errorResponse(
    statusCode: Int,
    code: String,
    message: String,
    headers: [String: String] = [:]
  ) -> RemoteControlHTTPResponse {
    .json(
      statusCode: statusCode, payload: RemoteControlErrorPayload(error: .init(code: code, message: message)),
      headers: headers)
  }

  private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let lhsBytes = Array(lhs.utf8)
    let rhsBytes = Array(rhs.utf8)
    let count = max(lhsBytes.count, rhsBytes.count)
    var difference = lhsBytes.count ^ rhsBytes.count
    for index in 0..<count {
      let lhsByte = index < lhsBytes.count ? lhsBytes[index] : 0
      let rhsByte = index < rhsBytes.count ? rhsBytes[index] : 0
      difference |= Int(lhsByte ^ rhsByte)
    }
    return difference == 0
  }

  private func limit(_ text: String, maximumLines: Int, maximumBytes: Int) -> (text: String, truncated: Bool) {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let lineLimitedText = lines.suffix(maximumLines).map(String.init).joined(separator: "\n")
    let wasLineTruncated = lines.count > maximumLines
    guard lineLimitedText.utf8.count > maximumBytes else { return (lineLimitedText, wasLineTruncated) }

    var byteCount = 0
    var suffix: [Character] = []
    for character in lineLimitedText.reversed() {
      let characterByteCount = String(character).utf8.count
      guard byteCount + characterByteCount <= maximumBytes else { break }
      suffix.append(character)
      byteCount += characterByteCount
    }
    return (String(suffix.reversed()), true)
  }

  private func lineCount(in text: String) -> Int {
    guard !text.isEmpty else { return 0 }
    return text.split(separator: "\n", omittingEmptySubsequences: false).count
  }
}

private struct RemoteControlAgentsPayload: Codable {
  let count: Int
  let agents: [RemoteControlAgent]
}

private struct RemoteControlAgent: Codable {
  let id: String
  let type: String
  let name: String
  let status: String
  let project: Project
  let lastChangedAt: String

  private enum CodingKeys: String, CodingKey {
    case id, type, name, status, project
    case lastChangedAt = "last_changed_at"
  }

  struct Project: Codable {
    let name: String
    let branch: String
  }
}

private struct RemoteControlReadPayload: Codable {
  let agentID: String
  let source: String
  let lineCount: Int
  let text: String
  let truncated: Bool

  private enum CodingKeys: String, CodingKey {
    case agentID = "agent_id"
    case source
    case lineCount = "line_count"
    case text
    case truncated
  }
}

private struct RemoteControlErrorPayload: Codable {
  let error: RemoteControlError

  struct RemoteControlError: Codable {
    let code: String
    let message: String
  }
}
