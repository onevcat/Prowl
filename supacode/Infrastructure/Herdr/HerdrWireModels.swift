import Foundation

nonisolated internal enum HerdrProcessDetector {
  internal static func isHerdr(_ job: ForegroundJob?) -> Bool {
    guard let job else { return false }
    return job.processes.contains { process in
      [process.argv0, process.name]
        .compactMap { $0.flatMap(ProcessDetection.basename)?.lowercased() }
        .contains("herdr")
    }
  }
}

nonisolated internal enum HerdrSocketPathResolver {
  internal static func defaultPath(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> String {
    let configurationDirectory: URL
    if let xdgPath = environment["XDG_CONFIG_HOME"], !xdgPath.isEmpty {
      configurationDirectory = URL(filePath: xdgPath, directoryHint: .isDirectory)
    } else {
      configurationDirectory = homeDirectory.appending(path: ".config", directoryHint: .isDirectory)
    }
    return
      configurationDirectory
      .appending(path: "herdr", directoryHint: .isDirectory)
      .appending(path: "herdr.sock", directoryHint: .notDirectory)
      .path(percentEncoded: false)
  }
}

nonisolated internal struct HerdrPaneInfo: Decodable, Equatable, Sendable {
  internal let paneID: String
  internal let agent: String?
  internal let agentStatus: String?

  internal var inputContext: TerminalInputContext {
    agent == nil ? .commandLike : .chatAgent
  }

  nonisolated private enum CodingKeys: String, CodingKey {
    case paneID = "pane_id"
    case agent
    case agentStatus = "agent_status"
  }
}

nonisolated internal struct HerdrResponseEnvelope: Decodable, Sendable {
  nonisolated internal struct Result: Decodable, Sendable {
    internal let type: String
    internal let pane: HerdrPaneInfo?
    internal let protocolVersion: UInt32?

    nonisolated private enum CodingKeys: String, CodingKey {
      case type
      case pane
      case protocolVersion = "protocol"
    }
  }

  nonisolated internal struct ErrorBody: Decodable, Sendable {
    internal let code: String
    internal let message: String
  }

  internal let id: String?
  internal let result: Result?
  internal let error: ErrorBody?

  internal var currentPane: HerdrPaneInfo? {
    guard result?.type == "pane_current" else { return nil }
    return result?.pane
  }
}

nonisolated internal enum HerdrProtocolCompatibility {
  internal static let supportedVersions: ClosedRange<UInt32> = 19...20

  internal static func validate(_ response: HerdrResponseEnvelope) throws {
    guard response.result?.type == "pong" else {
      throw HerdrSocketError.unsupportedResponseType(response.result?.type)
    }
    let actualVersion = response.result?.protocolVersion
    guard let actualVersion, supportedVersions.contains(actualVersion) else {
      throw HerdrSocketError.unsupportedProtocol(
        supported: supportedVersions,
        actual: actualVersion
      )
    }
  }
}

nonisolated internal struct HerdrEventEnvelope: Decodable, Sendable {
  internal let event: String
}

nonisolated internal struct HerdrRequest<Params: Encodable>: Encodable {
  internal let id: String
  internal let method: String
  internal let params: Params
}

nonisolated internal struct HerdrEmptyParams: Encodable, Sendable {}

nonisolated internal struct HerdrEventsSubscribeParams: Encodable, Sendable {
  nonisolated internal struct Subscription: Encodable, Sendable {
    internal let type: String
  }

  internal let subscriptions: [Subscription]
}
