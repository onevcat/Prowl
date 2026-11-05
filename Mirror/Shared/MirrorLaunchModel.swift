import Foundation
import Observation

nonisolated struct MirrorLaunchWorktree: Decodable, Identifiable, Equatable {
  let id: String
  let name: String
  let path: String
  let rootPath: String
  enum CodingKeys: String, CodingKey {
    case id, name, path
    case rootPath = "root_path"
  }
  var label: String { "\(URL(fileURLWithPath: rootPath).lastPathComponent) · \(name)" }
}

nonisolated struct MirrorLaunchProfile: Decodable, Identifiable, Equatable {
  let id: String
  let name: String
  let enabled: Bool
  let runtime: String
  let availability: Availability
  /// The Profile's model, reasoning effort and SF Symbol, when it sets them (docs-ai 089 S3).
  var model: String?
  var effort: String?
  var icon: String?
  struct Availability: Decodable, Equatable {
    let status: String
    let reason: String?
  }
  var isAvailable: Bool { enabled && availability.status == "available" }

  enum CodingKeys: String, CodingKey {
    case id, name, enabled, runtime, availability, model, icon
    case effort = "reasoning_effort"
  }
}

@MainActor
@Observable
final class MirrorLaunchModel {
  enum Kind: Hashable { case shell, agent }
  let supportsShell: Bool
  let supportsProfiles: Bool
  var kind: Kind
  var worktreeID: String?
  var profileID: String?
  var prompt = ""
  private(set) var worktrees: [MirrorLaunchWorktree] = []
  private(set) var profiles: [MirrorLaunchProfile] = []
  private(set) var isLoading = false
  private(set) var isCreating = false
  private(set) var error: String?
  private(set) var creationUncertain = false
  private let execute: (MirrorCommandRequest.Command) async throws -> MirrorJSON

  init(
    supportsShell: Bool = false, supportsProfiles: Bool = true,
    execute: @escaping (MirrorCommandRequest.Command) async throws -> MirrorJSON
  ) {
    self.supportsShell = supportsShell
    self.supportsProfiles = supportsProfiles
    kind = supportsShell ? .shell : .agent
    self.execute = execute
  }

  var canCreate: Bool {
    !isLoading && !isCreating && !creationUncertain
      && worktrees.contains { $0.id == worktreeID }
      && (kind == .shell
        ? supportsShell
        : supportsProfiles && profiles.contains { $0.id == profileID && $0.isAvailable }
          && prompt.utf8.count <= MirrorWire.maximumInput)
  }

  func load() async {
    guard !isLoading, !isCreating, !creationUncertain else { return }
    isLoading = true
    error = nil
    defer { isLoading = false }
    worktrees = []
    profiles = []
    do {
      let listing: Listing = try await response(.list(.init()))
      var seen: Set<String> = []
      worktrees = (listing.worktrees ?? listing.items.map(\.worktree)).filter {
        seen.insert($0.id).inserted
      }
      worktreeIDsByPane = Dictionary(
        listing.items.compactMap { item in item.pane.map { ($0.id.uppercased(), item.worktree.id) } },
        uniquingKeysWith: { first, _ in first })
      if projectPaneIDs != nil {
        applyProjectSelection()
      } else if !worktrees.contains(where: { $0.id == worktreeID }) {
        worktreeID = worktrees.first?.id
      }
      if supportsProfiles {
        let catalog: Catalog = try await response(.profiles(.init()))
        profiles = catalog.profiles
      }
      if !profiles.contains(where: { $0.id == profileID && $0.isAvailable }) {
        profileID = profiles.first(where: \.isAvailable)?.id
      }
    } catch { self.error = error.localizedDescription }
  }

  /// The panes of the project the person started from (docs-ai 089). While set, the
  /// selection only takes a worktree that holds one of them, also after a reload.
  private(set) var projectPaneIDs: [String]?
  /// Worktree IDs (which carry the origin, such as an SSH host) by the pane IDs `list` reports.
  private var worktreeIDsByPane: [String: String] = [:]

  /// Restricts the selection to the worktrees of these panes: the project's main worktree when
  /// one of them is it, otherwise the first. With no match nothing is selected, so a
  /// project-specific launch never runs in another repository or on another host.
  func focusProject(paneIDs: [String]) {
    projectPaneIDs = paneIDs.map { $0.uppercased() }
    applyProjectSelection()
  }

  private func applyProjectSelection() {
    guard let projectPaneIDs else { return }
    func normalized(_ path: String) -> String {
      var path = path
      while path.count > 1, path.hasSuffix("/") { path.removeLast() }
      return path
    }
    let wanted = Set(projectPaneIDs.compactMap { worktreeIDsByPane[$0] })
    let matches = worktrees.filter { wanted.contains($0.id) }
    worktreeID = (matches.first { normalized($0.path) == normalized($0.rootPath) } ?? matches.first)?.id
  }

  func create() async -> MirrorPaneDescriptor? {
    guard canCreate, let worktreeID else { return nil }
    let launchedProfile = kind == .shell ? nil : profiles.first { $0.id == profileID }
    isCreating = true
    error = nil
    defer { isCreating = false }
    do {
      let request: MirrorCommandRequest.Create
      if kind == .shell {
        request = .init(worktreeID: worktreeID)
      } else {
        guard let profileID else { return nil }
        request = .init(
          worktreeID: worktreeID, profileID: profileID,
          prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prompt)
      }
      let created: Created = try await response(.create(request))
      guard let id = UUID(uuidString: created.target.pane.id) else {
        throw LaunchError.invalidResponse
      }
      let worktree = created.target.worktree
      // The Host names the tab after the agent only once it starts; until the roster says
      // more, the pane carries the Profile's name and agent (docs-ai 089 D1).
      let profile = launchedProfile
      let hostTitle = created.target.pane.title.trimmingCharacters(in: .whitespacesAndNewlines)
      let title = hostTitle.isEmpty ? profile?.name ?? String(localized: "Shell") : hostTitle
      return MirrorPaneDescriptor(
        id: id, title: title, directory: worktree.path, busy: false,
        projectName: URL(fileURLWithPath: worktree.rootPath).lastPathComponent,
        subtitle: "\(title) · \(worktree.name)",
        agent: profile?.runtime)
    } catch {
      // A transport failure may follow a successful creation. Never automatically create again.
      creationUncertain =
        !(error is Rejected) || (error as? Rejected)?.code == "REMOTE_COMMAND_UNCONFIRMED"
      self.error =
        creationUncertain
        ? "Creation is unconfirmed. Refresh the Host pane list before creating another pane."
        : error.localizedDescription
      return nil
    }
  }

  private func response<T: Decodable>(_ command: MirrorCommandRequest.Command) async throws -> T {
    let result = try await execute(command).decode(Response<T>.self)
    guard result.ok else {
      throw result.error ?? Rejected(code: nil, message: "Host rejected the command.")
    }
    guard let payload = result.data else { throw LaunchError.invalidResponse }
    return payload
  }

  private struct Response<T: Decodable>: Decodable {
    let ok: Bool
    let data: T?
    let error: Rejected?
  }
  private struct Rejected: Decodable, LocalizedError {
    let code: String?
    let message: String
    var errorDescription: String? { message }
  }
  private enum LaunchError: LocalizedError {
    case invalidResponse
    var errorDescription: String? { "Host returned an invalid launch result." }
  }
  private struct Listing: Decodable {
    struct Item: Decodable {
      struct Pane: Decodable { let id: String }
      let worktree: MirrorLaunchWorktree
      let pane: Pane?
    }
    let items: [Item]
    let worktrees: [MirrorLaunchWorktree]?
  }
  private struct Catalog: Decodable { let profiles: [MirrorLaunchProfile] }
  private struct Created: Decodable {
    struct Target: Decodable {
      struct Pane: Decodable {
        let id: String
        let title: String
      }
      let worktree: MirrorLaunchWorktree
      let pane: Pane
    }
    let target: Target
  }
}
