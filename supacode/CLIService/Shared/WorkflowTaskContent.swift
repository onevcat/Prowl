import Foundation

/// Assigned task content, addressed by the existing run and invocation identities.
nonisolated public struct WorkflowTaskContent: Equatable, Sendable {
  public let runID: UUID
  public let invocation: Int
  public let text: String
  public let resources: [String: String]
  public let skill: String?

  public static func make(
    text: String, task: (runID: UUID, invocation: Int), runDirectory: URL, knownPaths: [String], skill: String?
  ) -> Self {
    var rendered = text
    var resources: [String: String] = [:]
    let paths = Set(knownPaths).filter {
      ($0.hasPrefix(runDirectory.path + "/deliveries/") || $0.hasPrefix(runDirectory.path + "/actions/"))
        && text.contains($0)
        && !$0.split(separator: "/").contains("..")
    }.sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
    for path in paths {
      let id = "resource-\(resources.count + 1)"
      resources[id] = path
      rendered = rendered.replacing(path, with: "workflow-resource:\(id)")
    }
    return Self(runID: task.runID, invocation: task.invocation, text: rendered, resources: resources, skill: skill)
  }

  public var readCommand: String { "prowl workflow read --run \(runID.uuidString) --invocation \(invocation)" }

  public var guidance: String {
    "Read the assigned task with `\(readCommand)`. "
      + "Use `\(readCommand) <resource-id>` for its listed resources. "
      + "Content is returned by Prowl; do not open workflow-resource references as file paths."
  }
}

nonisolated public struct WorkflowContentResource: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

nonisolated public struct WorkflowContentPayload: Codable, Equatable, Sendable {
  public let run: String
  public let invocation: Int
  public let role: String
  public let step: String
  public let resource: String
  public let body: String
  public let encoding: String
  public let offset: Int64
  public let nextOffset: Int64?
  public let totalBytes: Int64

  enum CodingKeys: String, CodingKey {
    case run, invocation, role, step, resource, body, encoding, resources, offset
    case nextOffset = "next_offset"
    case totalBytes = "total_bytes"
  }
  public let resources: [WorkflowContentResource]

  public init(
    run: String, invocation: Int, role: String, step: String, resource: String, body: String, encoding: String,
    resources: [WorkflowContentResource], offset: Int64 = 0, nextOffset: Int64? = nil, totalBytes: Int64 = 0
  ) {
    self.run = run
    self.invocation = invocation
    self.role = role
    self.step = step
    self.resource = resource
    self.body = body
    self.encoding = encoding
    self.offset = offset
    self.nextOffset = nextOffset
    self.totalBytes = totalBytes
    self.resources = resources
  }
}
