import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct AgentSkillsFeatureTests {
  @Test(.dependencies) func taskListsUserSkillsWithDetectedTargetsOnly() async throws {
    let fixture = try SkillInstallFixture()
    defer { fixture.cleanup() }
    let store = makeStore(fixture.client)

    await store.send(.task) {
      $0.skills = [
        try fixture.row("prowl-cli", links: [("claude", .notInstalled), ("agents", .notInstalled)])
      ]
    }
  }

  @Test(.dependencies) func taskReportsAMissingBundle() async {
    var client = SkillInstallClient.testValue
    client.bundledSkills = { throw SkillInstallError(message: "Bundled skills were not found at /nowhere/skills.") }
    let store = makeStore(client)

    await store.send(.task) {
      $0.loadError = "Bundled skills were not found at /nowhere/skills."
    }
  }

  @Test(.dependencies) func installLinksTheSkillAndRefreshesTheRow() async throws {
    let fixture = try SkillInstallFixture()
    defer { fixture.cleanup() }
    let store = makeStore(fixture.client)
    await store.send(.task) {
      $0.skills = [
        try fixture.row("prowl-cli", links: [("claude", .notInstalled), ("agents", .notInstalled)])
      ]
    }

    await store.send(.installLink(skillID: "prowl-cli", targetID: "claude"))
    await store.receive(\.linkChangeCompleted.success) {
      $0.skills[id: "prowl-cli"]?.links[id: "claude"]?.status =
        .installed(path: fixture.linkPath(target: ".claude", skill: "prowl-cli"))
    }
    await store.receive(.delegate(.linkChanged(.installed(skill: "prowl-cli", target: "Claude Code"))))

    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: fixture.linkPath(target: ".claude", skill: "prowl-cli"))
        == fixture.skillDirectory("prowl-cli")
    )
    #expect(!FileManager.default.fileExists(atPath: fixture.linkPath(target: ".agents", skill: "prowl-cli")))
  }

  @Test(.dependencies) func removeDeletesTheLinkAndRefreshesTheRow() async throws {
    let fixture = try SkillInstallFixture()
    defer { fixture.cleanup() }
    try fixture.link(target: ".claude", skill: "prowl-cli", to: fixture.skillDirectory("prowl-cli"))
    let claudePath = fixture.linkPath(target: ".claude", skill: "prowl-cli")
    let store = makeStore(fixture.client)
    await store.send(.task) {
      $0.skills = [
        try fixture.row("prowl-cli", links: [("claude", .installed(path: claudePath)), ("agents", .notInstalled)])
      ]
    }

    await store.send(.removeLink(skillID: "prowl-cli", targetID: "claude"))
    await store.receive(\.linkChangeCompleted.success) {
      $0.skills[id: "prowl-cli"]?.links[id: "claude"]?.status = .notInstalled
    }
    await store.receive(.delegate(.linkChanged(.removed(skill: "prowl-cli", target: "Claude Code"))))

    #expect((try? FileManager.default.attributesOfItem(atPath: claudePath)) == nil)
    #expect(FileManager.default.fileExists(atPath: fixture.skillDirectory("prowl-cli")))
  }

  @Test(.dependencies) func installRepairsABrokenLink() async throws {
    let fixture = try SkillInstallFixture()
    defer { fixture.cleanup() }
    let gone = fixture.root.appending(path: "gone").path(percentEncoded: false)
    try fixture.link(target: ".claude", skill: "prowl-cli", to: gone)
    let claudePath = fixture.linkPath(target: ".claude", skill: "prowl-cli")
    let store = makeStore(fixture.client)
    await store.send(.task) {
      $0.skills = [
        try fixture.row(
          "prowl-cli",
          links: [("claude", .broken(path: claudePath, destination: gone)), ("agents", .notInstalled)]
        )
      ]
    }

    await store.send(.installLink(skillID: "prowl-cli", targetID: "claude"))
    await store.receive(\.linkChangeCompleted.success) {
      $0.skills[id: "prowl-cli"]?.links[id: "claude"]?.status = .installed(path: claudePath)
    }
    await store.receive(.delegate(.linkChanged(.installed(skill: "prowl-cli", target: "Claude Code"))))
  }

  @Test(.dependencies) func installReplacesALinkToAnotherBuild() async throws {
    let fixture = try SkillInstallFixture()
    defer { fixture.cleanup() }
    let debugBuild = fixture.root.appending(path: "DerivedData/skills/prowl-cli", directoryHint: .isDirectory)
    try fixture.makeDirectory(debugBuild)
    let debugPath = debugBuild.path(percentEncoded: false).trimmingTrailingPathSeparator()
    try fixture.link(target: ".agents", skill: "prowl-cli", to: debugPath)
    let agentsPath = fixture.linkPath(target: ".agents", skill: "prowl-cli")
    let store = makeStore(fixture.client)
    await store.send(.task) {
      $0.skills = [
        try fixture.row(
          "prowl-cli",
          links: [
            ("claude", .notInstalled),
            ("agents", .installedDifferentSource(path: agentsPath, destination: debugPath)),
          ]
        )
      ]
    }

    await store.send(.installLink(skillID: "prowl-cli", targetID: "agents"))
    await store.receive(\.linkChangeCompleted.success) {
      $0.skills[id: "prowl-cli"]?.links[id: "agents"]?.status = .installed(path: agentsPath)
    }
    await store.receive(.delegate(.linkChanged(.installed(skill: "prowl-cli", target: "Shared agents directory"))))

    #expect(FileManager.default.fileExists(atPath: debugPath), "The other build's skill directory is never deleted")
  }

  @Test(.dependencies) func aliasedTargetsRefreshTogether() async throws {
    let fixture = try SkillInstallFixture()
    defer { fixture.cleanup() }
    _ = try fixture.aliasClaudeAndCodexSkills()
    let claudePath = fixture.linkPath(target: ".claude", skill: "prowl-cli")
    let codexPath = fixture.linkPath(target: ".codex", skill: "prowl-cli")
    let store = makeStore(fixture.client)
    await store.send(.task) {
      $0.skills = [
        try fixture.row(
          "prowl-cli",
          links: [("claude", .notInstalled), ("codex", .notInstalled), ("agents", .notInstalled)]
        )
      ]
    }

    await store.send(.installLink(skillID: "prowl-cli", targetID: "claude"))
    await store.receive(\.linkChangeCompleted.success) {
      $0.skills[id: "prowl-cli"]?.links[id: "claude"]?.status = .installed(path: claudePath)
      $0.skills[id: "prowl-cli"]?.links[id: "codex"]?.status = .installed(path: codexPath)
    }
    await store.receive(.delegate(.linkChanged(.installed(skill: "prowl-cli", target: "Claude Code"))))

    await store.send(.removeLink(skillID: "prowl-cli", targetID: "codex"))
    await store.receive(\.linkChangeCompleted.success) {
      $0.skills[id: "prowl-cli"]?.links[id: "claude"]?.status = .notInstalled
      $0.skills[id: "prowl-cli"]?.links[id: "codex"]?.status = .notInstalled
    }
    await store.receive(.delegate(.linkChanged(.removed(skill: "prowl-cli", target: "Codex"))))
  }

  @Test(.dependencies) func conflictShowsAnAlertAndLeavesTheDirectoryAlone() async throws {
    let fixture = try SkillInstallFixture()
    defer { fixture.cleanup() }
    let realDirectory = fixture.home.appending(path: ".claude/skills/prowl-cli", directoryHint: .isDirectory)
    try fixture.makeDirectory(realDirectory)
    try Data("keep".utf8).write(to: realDirectory.appending(path: "SKILL.md"))
    let claudePath = fixture.linkPath(target: ".claude", skill: "prowl-cli")
    let store = makeStore(fixture.client)
    await store.send(.task) {
      $0.skills = [
        try fixture.row(
          "prowl-cli",
          links: [
            ("claude", .installedDifferentSource(path: claudePath, destination: nil)),
            ("agents", .notInstalled),
          ]
        )
      ]
    }

    let message =
      "A real file or directory occupies \(claudePath). "
      + "Prowl only manages symlinks and never deletes it; remove it manually first."
    await store.send(.installLink(skillID: "prowl-cli", targetID: "claude"))
    await store.receive(\.linkChangeCompleted.failure) {
      $0.alert = AlertState {
        TextState("Agent Skills Error")
      } actions: {
        ButtonState(action: .dismiss) { TextState("OK") }
      } message: {
        TextState(message)
      }
    }
    await store.receive(.delegate(.linkChanged(.failed(message: message))))

    #expect(try Data(contentsOf: realDirectory.appending(path: "SKILL.md")) == Data("keep".utf8))

    await store.send(.alert(.presented(.dismiss))) {
      $0.alert = nil
    }
  }

  @Test(.dependencies) func revealHandsTheSkillToTheClient() async throws {
    let fixture = try SkillInstallFixture()
    defer { fixture.cleanup() }
    let revealed = LockIsolated<String?>(nil)
    var client = fixture.client
    client.revealSkill = { skill in revealed.setValue(skill.id) }
    let store = makeStore(client)
    await store.send(.task) {
      $0.skills = [
        try fixture.row("prowl-cli", links: [("claude", .notInstalled), ("agents", .notInstalled)])
      ]
    }

    await store.send(.revealSkillButtonTapped(skillID: "prowl-cli"))
    await store.finish()

    #expect(revealed.value == "prowl-cli")
  }

  @Test(.dependencies) func unknownSkillOrTargetIsIgnored() async throws {
    let fixture = try SkillInstallFixture()
    defer { fixture.cleanup() }
    let store = makeStore(fixture.client)
    await store.send(.task) {
      $0.skills = [
        try fixture.row("prowl-cli", links: [("claude", .notInstalled), ("agents", .notInstalled)])
      ]
    }

    await store.send(.installLink(skillID: "reviewer", targetID: "claude"))
    await store.send(.installLink(skillID: "prowl-cli", targetID: "codex"))
    await store.send(.removeLink(skillID: "prowl-cli", targetID: "codex"))
    await store.send(.revealSkillButtonTapped(skillID: "reviewer"))

    #expect(!FileManager.default.fileExists(atPath: fixture.linkPath(target: ".claude", skill: "reviewer")))
    #expect(!FileManager.default.fileExists(atPath: fixture.home.appending(path: ".codex").path()))
  }

  private func makeStore(_ client: SkillInstallClient) -> TestStoreOf<AgentSkillsFeature> {
    TestStore(initialState: AgentSkillsFeature.State()) {
      AgentSkillsFeature()
    } withDependencies: {
      $0.skillInstallClient = client
    }
  }
}

extension SkillInstallFixture {
  func row(
    _ skillID: String,
    links: [(target: String, status: SymlinkInstallStatus)]
  ) throws -> AgentSkillsFeature.SkillRow {
    AgentSkillsFeature.SkillRow(
      skill: try skill(skillID),
      links: IdentifiedArray(
        uniqueElements: try links.map { link in
          let target = try target(link.target)
          return AgentSkillsFeature.SkillLink(
            target: target,
            linkPath: linkPath(target: "." + link.target, skill: skillID),
            status: link.status
          )
        }
      )
    )
  }
}
