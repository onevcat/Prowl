import Foundation
import Observation

nonisolated struct MirrorLaunchWorktree: Decodable, Identifiable, Equatable {
  let id: String
  let name: String
  let path: String
  let rootPath: String
  enum CodingKeys: String, CodingKey { case id, name, path; case rootPath = "root_path" }
  var label: String { "\(URL(fileURLWithPath: rootPath).lastPathComponent) · \(name)" }
}

nonisolated struct MirrorLaunchProfile: Decodable, Identifiable, Equatable {
  let id: String
  let name: String
  let enabled: Bool
  let runtime: String
  let availability: Availability
  struct Availability: Decodable, Equatable { let status: String; let reason: String? }
  var isAvailable: Bool { enabled && availability.status == "available" }
}

@MainActor
@Observable
final class MirrorLaunchModel {
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

  init(execute: @escaping (MirrorCommandRequest.Command) async throws -> MirrorJSON) {
    self.execute = execute
  }

  var canCreate: Bool {
    !isLoading && !isCreating && !creationUncertain
      && worktrees.contains { $0.id == worktreeID }
      && profiles.contains { $0.id == profileID && $0.isAvailable }
      && prompt.utf8.count <= MirrorWire.maximumInput
  }

  func load() async {
    guard !isLoading, !isCreating else { return }
    isLoading = true
    error = nil
    defer { isLoading = false }
    do {
      let listing: Listing = try await response(.list(.init()))
      let catalog: Catalog = try await response(.profiles(.init()))
      var seen: Set<String> = []
      worktrees = listing.items.map(\.worktree).filter { seen.insert($0.id).inserted }
      profiles = catalog.profiles
      if !worktrees.contains(where: { $0.id == worktreeID }) { worktreeID = worktrees.first?.id }
      if !profiles.contains(where: { $0.id == profileID && $0.isAvailable }) {
        profileID = profiles.first(where: \.isAvailable)?.id
      }
    } catch { self.error = error.localizedDescription }
  }

  func create() async -> MirrorPaneDescriptor? {
    guard canCreate, let worktreeID, let profileID else { return nil }
    isCreating = true
    error = nil
    defer { isCreating = false }
    do {
      let created: Created = try await response(.create(.init(
        worktreeID: worktreeID, profileID: profileID,
        prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prompt)))
      guard let id = UUID(uuidString: created.target.pane.id) else { throw LaunchError.invalidResponse }
      let worktree = created.target.worktree
      return MirrorPaneDescriptor(
        id: id, title: created.target.pane.title, directory: worktree.path, busy: false,
        projectName: URL(fileURLWithPath: worktree.rootPath).lastPathComponent,
        subtitle: "\(created.target.pane.title) · \(worktree.name)")
    } catch {
      // A transport failure may follow a successful creation. Never automatically create again.
      creationUncertain = !(error is Rejected) || (error as? Rejected)?.code == "REMOTE_COMMAND_UNCONFIRMED"
      self.error = creationUncertain
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
    struct Item: Decodable { let worktree: MirrorLaunchWorktree }
    let items: [Item]
  }
  private struct Catalog: Decodable { let profiles: [MirrorLaunchProfile] }
  private struct Created: Decodable {
    struct Target: Decodable {
      struct Pane: Decodable { let id: String; let title: String }
      let worktree: MirrorLaunchWorktree
      let pane: Pane
    }
    let target: Target
  }
}
