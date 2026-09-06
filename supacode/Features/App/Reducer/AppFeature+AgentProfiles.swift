import ComposableArchitecture
import Foundation
import ProwlCLIShared
import Sharing

extension AppFeature {
  /// The single profile-launch path (docs-ai 053): every entry point (Agents
  /// menu, Command Palette) dispatches here, so placement, identity recording,
  /// and the environment patch always agree. The per-repo launch memory that
  /// backs the Recommended resolution is recorded on the terminal's
  /// `agentProfileLaunched` event — never here, so a launch that fails to
  /// create a surface cannot shift the recommendation (docs-ai 053/005).
  func launchAgentProfile(_ profileID: AgentProfile.ID, state: inout State) -> Effect<Action> {
    @Shared(.userGlobalSettings) var userGlobalSettings
    guard
      let profile = userGlobalSettings.agentProfiles.first(where: { $0.id == profileID }),
      profile.isEnabled,
      let worktree = actionTargetWorktree(repositories: state.repositories)
    else { return .none }

    let plan: AgentProfileLaunchPlan
    do {
      plan = try AgentProfileLaunchPlanner.plan(
        for: profile,
        homeBaseDirectory: SupacodePaths.agentProfileHomesDirectory
      )
    } catch {
      appLogger.warning("Agent profile launch planning failed: \(error)")
      return .send(.repositories(.showToast(.warning("Couldn't launch “\(profile.name)”"))))
    }

    return .run { _ in
      await terminalClient.send(.launchAgentProfile(worktree, plan: plan))
    }
  }
}

/// One-shot seeding of bare presets for installed runtimes (docs-ai 053).
/// Runs at app launch, outside the reducer: it is a migration-style side
/// effect, and deleted seeds must never respawn (the flag flips exactly once).
@MainActor
enum AgentProfileSeeder {
  static func seedIfNeeded(
    isRuntimeInstalled: (AgentProfileRuntime) -> Bool = AgentProfileAvailability.isRuntimeInstalled
  ) {
    @Shared(.userGlobalSettings) var settings
    guard !settings.didSeedAgentProfiles else { return }
    let seeded = AgentProfileRuntime.allCases.filter(isRuntimeInstalled).map { runtime in
      AgentProfile(
        name: AgentRuntimeAdapterRegistry.displayName(for: runtime),
        runtime: runtime
      )
    }
    $settings.withLock {
      $0.didSeedAgentProfiles = true
      guard $0.agentProfiles.isEmpty else { return }
      $0.agentProfiles = AgentProfile.normalizedProfiles(seeded)
    }
  }

}
