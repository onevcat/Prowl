import Foundation
import IdentifiedCollections

nonisolated struct Repository: Identifiable, Hashable, Sendable {
  enum Kind: String, Codable, Hashable, Sendable {
    case git
    case plain
  }

  struct Capabilities: Equatable, Hashable, Sendable {
    let supportsWorktrees: Bool
    let supportsBranchOperations: Bool
    let supportsPullRequests: Bool
    let supportsCodeHost: Bool
    let supportsDiff: Bool
    let supportsGitStatus: Bool
    let supportsRunnableFolderActions: Bool
    let supportsRepositoryGitSettings: Bool

    static let git = Capabilities(
      supportsWorktrees: true,
      supportsBranchOperations: true,
      supportsPullRequests: true,
      supportsCodeHost: true,
      supportsDiff: true,
      supportsGitStatus: true,
      supportsRunnableFolderActions: true,
      supportsRepositoryGitSettings: true
    )

    static let plain = Capabilities(
      supportsWorktrees: false,
      supportsBranchOperations: false,
      supportsPullRequests: false,
      supportsCodeHost: false,
      supportsDiff: false,
      supportsGitStatus: false,
      supportsRunnableFolderActions: true,
      supportsRepositoryGitSettings: false
    )
  }

  let id: String
  let rootURL: URL
  let name: String
  let kind: Kind
  let worktrees: IdentifiedArrayOf<Worktree>
  let workspace: ProjectWorkspace?

  init(
    id: String,
    rootURL: URL,
    name: String,
    kind: Kind = .git,
    worktrees: IdentifiedArrayOf<Worktree>,
    workspace: ProjectWorkspace? = nil
  ) {
    self.id = id
    self.rootURL = rootURL
    self.name = name
    // A workspace is always a plain runnable folder; git capabilities stay per-repository.
    self.kind = workspace == nil ? kind : .plain
    self.worktrees = worktrees
    self.workspace = workspace
  }

  var initials: String {
    Self.initials(from: name)
  }

  var capabilities: Capabilities {
    switch kind {
    case .git:
      .git
    case .plain:
      .plain
    }
  }

  var isWorkspace: Bool {
    workspace != nil
  }

  static func name(for rootURL: URL) -> String {
    let name = rootURL.lastPathComponent
    if name == ".bare" || name == ".git" {
      let parentName = rootURL.deletingLastPathComponent().lastPathComponent
      if !parentName.isEmpty, parentName != "/" {
        return parentName
      }
    }
    if name.isEmpty {
      return rootURL.path(percentEncoded: false)
    }
    return name
  }

  static func initials(from name: String) -> String {
    var parts: [String] = []
    var current = ""
    for character in name {
      if character.isLetter || character.isNumber {
        current.append(character)
      } else if !current.isEmpty {
        parts.append(current)
        current = ""
      }
    }
    if !current.isEmpty {
      parts.append(current)
    }
    let initials: String
    if parts.count >= 2 {
      let first = parts[0].prefix(1)
      let second = parts[1].prefix(1)
      initials = String(first + second)
    } else if let part = parts.first {
      initials = String(part.prefix(2))
    } else {
      initials = String(name.prefix(2))
    }
    return initials.uppercased()
  }
}
