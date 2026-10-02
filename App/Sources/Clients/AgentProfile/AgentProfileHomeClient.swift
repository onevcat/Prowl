import AppKit
import Dependencies
import Foundation

/// All filesystem access for agent profile homes (docs-ai 053). Every
/// operation re-derives the path from the profile UUID and enforces the
/// profile-home base containment, so no caller can ever touch a real agent
/// home; tests inject stubs and never reach login directories.
struct AgentProfileHomeClient: Sendable {
  var homeExists: @Sendable (AgentProfile.ID) -> Bool
  var revealHome: @Sendable (AgentProfile.ID) -> Void
  var trashHome: @Sendable (AgentProfile.ID) async throws -> Void
}

extension AgentProfileHomeClient: DependencyKey {
  static let liveValue = AgentProfileHomeClient(
    homeExists: { id in
      guard let home = containedHome(for: id) else { return false }
      return FileManager.default.fileExists(atPath: AgentProfileLaunchPlanner.pathString(home))
    },
    revealHome: { id in
      guard let home = containedHome(for: id) else { return }
      // provision re-runs the physical containment gate (symlink leaf,
      // canonical base escape) before touching anything.
      try? AgentProfileHomeProvisioner.provision(
        home: home,
        base: SupacodePaths.agentProfileHomesDirectory
      )
      NSWorkspace.shared.activateFileViewerSelecting([home])
    },
    trashHome: { id in
      guard let home = containedHome(for: id) else { return }
      try AgentProfileHomeProvisioner.validatePhysicalContainment(
        home: home,
        base: SupacodePaths.agentProfileHomesDirectory
      )
      guard FileManager.default.fileExists(atPath: AgentProfileLaunchPlanner.pathString(home)) else {
        return
      }
      // Trash, never rm: a mis-click on a home holding real credentials must
      // stay recoverable.
      try FileManager.default.trashItem(at: home, resultingItemURL: nil)
    }
  )

  static let testValue = AgentProfileHomeClient(
    homeExists: { _ in false },
    revealHome: { _ in },
    trashHome: { _ in }
  )

  private nonisolated static func containedHome(for id: AgentProfile.ID) -> URL? {
    let base = SupacodePaths.agentProfileHomesDirectory
    let home = AgentProfileLaunchPlanner.dedicatedHomeDirectory(for: id, base: base)
    return AgentProfileLaunchPlanner.isContained(home, in: base) ? home : nil
  }
}
