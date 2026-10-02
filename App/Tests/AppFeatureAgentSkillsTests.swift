import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct AppFeatureAgentSkillsTests {
  @Test(.dependencies) func skillLinkResultsShowToasts() async {
    var state = AppFeature.State(settings: SettingsFeature.State())
    state.settings.selection = .commandLineTool
    state.settings.agentSkills = .init()
    let store = TestStore(initialState: state) {
      AppFeature()
    }
    // The toast auto-dismiss sleeps on a real clock, exactly like the CLI install toast test.
    store.exhaustivity = .off

    await store.send(
      .settings(.agentSkills(.delegate(.linkChanged(.installed(skill: "prowl-cli", target: "Claude Code")))))
    )
    await store.receive(\.repositories.showToast) {
      $0.repositories.statusToast = .success("prowl-cli skill linked for Claude Code")
    }

    await store.send(.settings(.agentSkills(.delegate(.linkChanged(.removed(skill: "prowl-cli", target: "Codex"))))))
    await store.receive(\.repositories.showToast) {
      $0.repositories.statusToast = .success("prowl-cli skill link removed for Codex")
    }

    await store.send(.settings(.agentSkills(.delegate(.linkChanged(.failed(message: "boom"))))))
    await store.receive(\.repositories.showToast) {
      $0.repositories.statusToast = .warning("Skill link failed: boom")
    }
  }

  /// Leaving the CLI & Skills page removes the child state; the in-flight link effect must be
  /// cancelled with it, or its completion lands on nil state and the outcome is never reported.
  @Test(.dependencies, arguments: [AgentSkillsFeatureTests.LinkAction.install, .remove])
  func switchingSectionsCancelsAnInFlightLinkEffect(action: AgentSkillsFeatureTests.LinkAction) async throws {
    let fixture = try SkillInstallFixture()
    defer { fixture.cleanup() }
    let clock = TestClock()
    var client = fixture.client
    client.install = { _, _ in try await clock.sleep(for: .seconds(1)) }
    client.uninstall = { _, _ in try await clock.sleep(for: .seconds(1)) }
    let store = TestStore(initialState: AppFeature.State(settings: SettingsFeature.State())) {
      AppFeature()
    } withDependencies: {
      $0.skillInstallClient = client
    }

    await store.send(.settings(.setSelection(.commandLineTool))) {
      $0.settings.selection = .commandLineTool
      $0.settings.agentSkills = .init()
    }
    await store.send(.settings(.agentSkills(.task))) {
      $0.settings.agentSkills?.skills = [
        try fixture.row("prowl-cli", links: [("claude", .notInstalled), ("agents", .notInstalled)])
      ]
    }
    switch action {
    case .install:
      await store.send(.settings(.agentSkills(.installLink(skillID: "prowl-cli", targetID: "claude"))))
    case .remove:
      await store.send(.settings(.agentSkills(.removeLink(skillID: "prowl-cli", targetID: "claude"))))
    }

    await store.send(.settings(.setSelection(.general))) {
      $0.settings.selection = .general
      $0.settings.agentSkills = nil
    }
    // The suspended operation is cancelled with the child state; nothing may complete afterwards.
    await clock.advance(by: .seconds(1))
    await store.finish()
  }
}

extension AgentSkillsFeatureTests {
  enum LinkAction {
    case install
    case remove
  }
}
