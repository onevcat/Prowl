import Testing

@testable import supacode

struct EffectiveCustomCommandTests {
  @Test func repositoryCommandsKeepOrderAndGlobalCommandsFollowIncludingMatchingTitles() {
    let localBuild = command(id: "local-build", title: " Build ")
    let localTest = command(id: "local-test", title: "Test")
    let globalBuild = command(id: "global-build", title: "build")
    let globalLint = command(id: "global-lint", title: "Lint")

    let resolved = EffectiveCustomCommand.resolve(
      repositoryCommands: [localBuild, localTest],
      globalCommands: [globalBuild, globalLint]
    )

    #expect(
      resolved.map(\.id) == [
        .init(source: .repository, commandID: "local-build"),
        .init(source: .repository, commandID: "local-test"),
        .init(source: .global, commandID: "global-build"),
        .init(source: .global, commandID: "global-lint"),
      ]
    )
  }

  @Test func visibilityGatesExcludeDisabledCommands() {
    let localEnabled = command(id: "local-enabled", title: "Build")
    let localDisabled = command(id: "local-disabled", title: "Test", isEnabled: false)
    let globalEnabled = command(id: "global-enabled", title: "Lint")
    let globalDisabled = command(id: "global-disabled", title: "Format", isEnabled: false)
    let globalOptedOut = command(id: "global-opted-out", title: "Deploy")

    let resolved = EffectiveCustomCommand.resolve(
      repositoryCommands: [localEnabled, localDisabled],
      globalCommands: [globalEnabled, globalDisabled, globalOptedOut],
      disabledGlobalCommandIDs: ["global-opted-out"]
    )

    #expect(
      resolved.map(\.id) == [
        .init(source: .repository, commandID: "local-enabled"),
        .init(source: .global, commandID: "global-enabled"),
      ]
    )
  }

  @Test func sourceQualifiedIdentityPreventsLocalGlobalUUIDCollisions() {
    let local = EffectiveCustomCommand(source: .repository, command: command(id: "same", title: "Local"))
    let global = EffectiveCustomCommand(source: .global, command: command(id: "same", title: "Global"))

    #expect(local.id != global.id)
    #expect(local.keybindingID == "custom_command.same")
    #expect(global.keybindingID == "custom_command.global.same")
    #expect(local.paletteID == "custom-command.same")
    #expect(global.paletteID == "custom-command.global.same")
  }

  private func command(id: String, title: String, isEnabled: Bool = true) -> UserCustomCommand {
    UserCustomCommand(
      id: id,
      title: title,
      systemImage: "terminal",
      command: "echo \(title)",
      execution: .shellScript,
      shortcut: nil,
      isEnabled: isEnabled
    )
  }
}
