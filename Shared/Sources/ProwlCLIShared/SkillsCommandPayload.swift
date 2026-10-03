import Foundation

/// `prowl skills` response data, discriminated by `action`.
public enum SkillsCommandPayload: Codable, Equatable, Sendable {
  public static let schemaVersion = "prowl.cli.skills.v1"

  case list(SkillsListPayload)
  case install(SkillsChangePayload)
  case uninstall(SkillsChangePayload)
  case path(SkillsPathPayload)

  public var action: SkillsCommandAction {
    switch self {
    case .list: .list
    case .install: .install
    case .uninstall: .uninstall
    case .path: .path
    }
  }

  private enum CodingKeys: String, CodingKey {
    case action
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(SkillsCommandAction.self, forKey: .action) {
    case .list: self = .list(try SkillsListPayload(from: decoder))
    case .install: self = .install(try SkillsChangePayload(from: decoder))
    case .uninstall: self = .uninstall(try SkillsChangePayload(from: decoder))
    case .path: self = .path(try SkillsPathPayload(from: decoder))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(action, forKey: .action)
    switch self {
    case .list(let payload): try payload.encode(to: encoder)
    case .install(let payload), .uninstall(let payload): try payload.encode(to: encoder)
    case .path(let payload): try payload.encode(to: encoder)
    }
  }
}

public enum SkillsCommandAction: String, Codable, Equatable, Sendable {
  case list
  case install
  case uninstall
  case path
}

public enum SkillsCommandStatus: String, Codable, Equatable, Sendable {
  case notInstalled = "not_installed"
  case installed
  case installedDifferentSource = "installed_different_source"
  case broken

  public init(_ status: SymlinkInstallStatus) {
    switch status {
    case .notInstalled: self = .notInstalled
    case .installed: self = .installed
    case .installedDifferentSource: self = .installedDifferentSource
    case .broken: self = .broken
    }
  }
}

public struct SkillsListPayload: Codable, Equatable, Sendable {
  public let skills: [SkillsCommandSkill]

  public init(skills: [SkillsCommandSkill]) {
    self.skills = skills
  }
}

public struct SkillsCommandSkill: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let description: String
  public let audience: ProwlSkillAudience
  /// Canonical bundled skill directory.
  public let path: String
  public let targets: [SkillsCommandTargetStatus]

  public init(
    id: String,
    name: String,
    description: String,
    audience: ProwlSkillAudience,
    path: String,
    targets: [SkillsCommandTargetStatus]
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.audience = audience
    self.path = path
    self.targets = targets
  }
}

public struct SkillsCommandTargetStatus: Codable, Equatable, Sendable {
  public let id: String
  public let detected: Bool
  /// The link slot for this skill inside the target's skills directory.
  public let path: String
  public let status: SkillsCommandStatus
  /// Where a foreign or dangling link points; omitted for `installed`, `not_installed`, and a
  /// real file or directory occupying the slot.
  public let destination: String?

  public init(
    id: String,
    detected: Bool,
    path: String,
    status: SkillsCommandStatus,
    destination: String? = nil
  ) {
    self.id = id
    self.detected = detected
    self.path = path
    self.status = status
    self.destination = destination
  }
}

public struct SkillsChangePayload: Codable, Equatable, Sendable {
  public let scope: ProwlSkillScope
  /// The scope root: the home directory for `user`, the project root for `project`.
  public let root: String
  public let results: [SkillsCommandResult]
  /// Project-scope hygiene note; omitted for user scope.
  public let note: String?

  public init(scope: ProwlSkillScope, root: String, results: [SkillsCommandResult], note: String? = nil) {
    self.scope = scope
    self.root = root
    self.results = results
    self.note = note
  }
}

public struct SkillsCommandResult: Codable, Equatable, Sendable {
  public let skill: String
  public let target: String
  public let path: String
  public let before: SkillsCommandStatus
  public let after: SkillsCommandStatus

  public init(skill: String, target: String, path: String, before: SkillsCommandStatus, after: SkillsCommandStatus) {
    self.skill = skill
    self.target = target
    self.path = path
    self.before = before
    self.after = after
  }
}

public struct SkillsPathPayload: Codable, Equatable, Sendable {
  public let skill: SkillsCommandSkillReference

  public init(skill: SkillsCommandSkillReference) {
    self.skill = skill
  }
}

public struct SkillsCommandSkillReference: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let audience: ProwlSkillAudience
  public let path: String

  public init(id: String, name: String, audience: ProwlSkillAudience, path: String) {
    self.id = id
    self.name = name
    self.audience = audience
    self.path = path
  }
}
