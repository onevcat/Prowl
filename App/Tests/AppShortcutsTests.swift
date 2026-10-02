import CustomDump
import SwiftUI
import Testing

@testable import supacode

@MainActor
struct AppShortcutsTests {
  @Test func displaySymbolsMatchDisplay() {
    let shortcuts: [AppShortcut] = [
      AppShortcuts.openSettings,
      AppShortcuts.newWorktree,
      AppShortcuts.openRepository,
    ]

    for shortcut in shortcuts {
      expectNoDifference(shortcut.displaySymbols.joined(), shortcut.display)
    }
  }

  @Test func worktreeSelectionUsesControlNumberShortcuts() {
    expectNoDifference(
      AppShortcuts.worktreeSelection.map(\.display),
      ["⌃1", "⌃2", "⌃3", "⌃4", "⌃5", "⌃6", "⌃7", "⌃8", "⌃9"]
    )

    for shortcut in AppShortcuts.worktreeSelection {
      #expect(shortcut.modifiers == .control)
    }
  }

  @Test func terminalTabSelectionUsesCommandNumberShortcuts() {
    expectNoDifference(
      AppShortcuts.terminalTabSelection.map(\.display),
      ["⌘1", "⌘2", "⌘3", "⌘4", "⌘5", "⌘6", "⌘7", "⌘8", "⌘9"]
    )
  }

  @Test func selectionDisplayUsesResolvedOverrides() {
    let overrides = KeybindingUserOverrideStore(
      overrides: [
        AppShortcuts.CommandID.selectWorktree1: KeybindingUserOverride(
          binding: Keybinding(key: "m", modifiers: .init(control: true))
        ),
        AppShortcuts.CommandID.selectTerminalTab1: KeybindingUserOverride(
          binding: Keybinding(key: "j", modifiers: .init(command: true))
        ),
      ]
    )
    let resolved = KeybindingResolver.resolve(
      schema: .appResolverSchema(),
      userOverrides: overrides
    )

    #expect(AppShortcuts.worktreeSelectionDisplay(at: 0, in: resolved) == "⌃M")
    #expect(AppShortcuts.terminalTabSelectionDisplay(at: 0, in: resolved) == "⌘J")
    #expect(AppShortcuts.worktreeSelectionDisplay(at: 10, in: resolved) == nil)
    #expect(AppShortcuts.terminalTabSelectionDisplay(at: 10, in: resolved) == nil)
  }

  @Test func helpTextUsesResolvedShortcutAndHandlesDisabledBinding() {
    let defaultHelpText = AppShortcuts.helpText(
      title: "Run Script",
      commandID: AppShortcuts.CommandID.runScript,
      in: .appDefaults
    )
    #expect(defaultHelpText == "Run Script (⌘R)")

    let disabledOverrides = KeybindingUserOverrideStore(
      overrides: [
        AppShortcuts.CommandID.runScript: KeybindingUserOverride(
          binding: nil,
          isEnabled: false
        )
      ]
    )
    let resolvedDisabled = KeybindingResolver.resolve(
      schema: .appResolverSchema(),
      userOverrides: disabledOverrides
    )

    let disabledHelpText = AppShortcuts.helpText(
      title: "Run Script",
      commandID: AppShortcuts.CommandID.runScript,
      in: resolvedDisabled
    )
    #expect(disabledHelpText == "Run Script")
  }

  @Test func defaultGlobalShortcutTableMatchesPlan() {
    let agentIslandShortcut =
      AppShortcuts.defaultShortcut(for: AppShortcuts.CommandID.toggleAgentIsland)?.display
      ?? "Unassigned"
    expectNoDifference(
      [
        "openSettings=\(AppShortcuts.openSettings.display)",
        "toggleLeftSidebar=\(AppShortcuts.toggleLeftSidebar.display)",
        "toggleActiveAgentsPanel=\(AppShortcuts.toggleActiveAgentsPanel.display)",
        "toggleAgentIsland=\(agentIslandShortcut)",
        "runScript=\(AppShortcuts.runScript.display)",
        "stopRunScript=\(AppShortcuts.stopRunScript.display)",
        "checkForUpdates=\(AppShortcuts.checkForUpdates.display)",
        "showDiff=\(AppShortcuts.showDiff.display)",
        "openFinder=\(AppShortcuts.openFinder.display)",
        "openRepository=\(AppShortcuts.openRepository.display)",
        "selectTerminalTab1=\(AppShortcuts.selectTerminalTab1.display)",
        "selectTerminalTab2=\(AppShortcuts.selectTerminalTab2.display)",
        "selectTerminalTab3=\(AppShortcuts.selectTerminalTab3.display)",
        "selectTerminalTab4=\(AppShortcuts.selectTerminalTab4.display)",
        "selectTerminalTab5=\(AppShortcuts.selectTerminalTab5.display)",
        "selectTerminalTab6=\(AppShortcuts.selectTerminalTab6.display)",
        "selectTerminalTab7=\(AppShortcuts.selectTerminalTab7.display)",
        "selectTerminalTab8=\(AppShortcuts.selectTerminalTab8.display)",
        "selectTerminalTab9=\(AppShortcuts.selectTerminalTab9.display)",
        "selectPreviousTerminalTab=\(AppShortcuts.selectPreviousTerminalTab.display)",
        "selectNextTerminalTab=\(AppShortcuts.selectNextTerminalTab.display)",
        "selectPreviousTerminalPane=\(AppShortcuts.selectPreviousTerminalPane.display)",
        "selectNextTerminalPane=\(AppShortcuts.selectNextTerminalPane.display)",
        "selectTerminalPaneUp=\(AppShortcuts.selectTerminalPaneUp.display)",
        "selectTerminalPaneDown=\(AppShortcuts.selectTerminalPaneDown.display)",
        "selectTerminalPaneLeft=\(AppShortcuts.selectTerminalPaneLeft.display)",
        "selectTerminalPaneRight=\(AppShortcuts.selectTerminalPaneRight.display)",
      ],
      [
        "openSettings=⌘,",
        "toggleLeftSidebar=⌘⌃S",
        "toggleActiveAgentsPanel=⌘⌥P",
        "toggleAgentIsland=Unassigned",
        "runScript=⌘R",
        "stopRunScript=⌘.",
        "checkForUpdates=⌘⇧U",
        "showDiff=⌘⇧Y",
        "openFinder=⌘O",
        "openRepository=⌘⇧O",
        "selectTerminalTab1=⌘1",
        "selectTerminalTab2=⌘2",
        "selectTerminalTab3=⌘3",
        "selectTerminalTab4=⌘4",
        "selectTerminalTab5=⌘5",
        "selectTerminalTab6=⌘6",
        "selectTerminalTab7=⌘7",
        "selectTerminalTab8=⌘8",
        "selectTerminalTab9=⌘9",
        "selectPreviousTerminalTab=⌘⇧[",
        "selectNextTerminalTab=⌘⇧]",
        "selectPreviousTerminalPane=⌘[",
        "selectNextTerminalPane=⌘]",
        "selectTerminalPaneUp=⌘⌥↑",
        "selectTerminalPaneDown=⌘⌥↓",
        "selectTerminalPaneLeft=⌘⌥←",
        "selectTerminalPaneRight=⌘⌥→",
      ]
    )
  }

  @Test func configurableSystemFixedAndLocalInteractionShortcutsAreDefinedInRegistry() {
    let idToDisplay = Dictionary(
      AppShortcuts.bindings.compactMap { binding in
        binding.shortcut.map { (binding.id, $0.display) }
      },
      uniquingKeysWith: { first, _ in first }
    )
    let idToScope = Dictionary(
      AppShortcuts.bindings.map { ($0.id, $0.scope) },
      uniquingKeysWith: { first, _ in first }
    )

    expectNoDifference(
      idToDisplay["command_palette"],
      AppShortcuts.commandPalette.display
    )
    expectNoDifference(
      idToDisplay["toggle_active_agents_panel"],
      AppShortcuts.toggleActiveAgentsPanel.display
    )
    #expect(idToDisplay["toggle_agent_island"] == nil)
    expectNoDifference(
      idToDisplay["quit_application"],
      AppShortcuts.quitApplication.display
    )
    expectNoDifference(
      idToDisplay["rename_branch"],
      AppShortcuts.renameBranch.display
    )
    expectNoDifference(
      idToDisplay["select_all_canvas_cards"],
      AppShortcuts.selectAllCanvasCards.display
    )
    expectNoDifference(
      idToDisplay["arrange_canvas_cards"],
      AppShortcuts.arrangeCanvasCards.display
    )
    expectNoDifference(
      idToDisplay["organize_canvas_cards"],
      AppShortcuts.organizeCanvasCards.display
    )
    expectNoDifference(
      idToDisplay["tile_canvas_cards"],
      AppShortcuts.tileCanvasCards.display
    )

    #expect(idToScope["command_palette"] == .configurableAppAction)
    #expect(idToScope["toggle_active_agents_panel"] == .configurableAppAction)
    #expect(idToScope["toggle_agent_island"] == .configurableAppAction)
    #expect(idToScope["quit_application"] == .systemFixedAppAction)
    #expect(idToScope["rename_branch"] == .localInteraction)
    #expect(idToScope["select_all_canvas_cards"] == .localInteraction)
    #expect(idToScope["arrange_canvas_cards"] == .localInteraction)
    #expect(idToScope["organize_canvas_cards"] == .localInteraction)
    #expect(idToScope["tile_canvas_cards"] == .localInteraction)
  }

  @Test func agentIslandShortcutIsUnassignedByDefaultAndAcceptsAnOverride() {
    let commandID = AppShortcuts.CommandID.toggleAgentIsland
    #expect(ResolvedKeybindingMap.appDefaults.keybinding(for: commandID) == nil)

    let binding = Keybinding(key: "p", modifiers: .init(command: true, shift: true))
    let resolved = KeybindingResolver.resolve(
      schema: .appResolverSchema(),
      userOverrides: KeybindingUserOverrideStore(
        overrides: [commandID: KeybindingUserOverride(binding: binding)]
      )
    )

    #expect(resolved.keybinding(for: commandID) == binding)
  }

  @Test func canvasLayoutShortcutsUseCommandOptionFamily() {
    expectNoDifference(AppShortcuts.arrangeCanvasCards.display, "⌘⌥R")
    expectNoDifference(AppShortcuts.organizeCanvasCards.display, "⌘⌥G")
    expectNoDifference(AppShortcuts.tileCanvasCards.display, "⌘⌥T")
    #expect(AppShortcuts.arrangeCanvasCards.modifiers == [.command, .option])
    #expect(AppShortcuts.organizeCanvasCards.modifiers == [.command, .option])
    #expect(AppShortcuts.tileCanvasCards.modifiers == [.command, .option])
  }

  @Test func userOverrideConflictsDetectsReservedAppShortcuts() {
    let commands = [
      UserCustomCommand(
        title: "Build",
        systemImage: "hammer",
        command: "swift build",
        execution: .shellScript,
        shortcut: UserCustomShortcut(
          key: "s",
          modifiers: UserCustomShortcutModifiers(command: true, control: true)
        )
      ),
      UserCustomCommand(
        title: "Deploy",
        systemImage: "rocket",
        command: "make release",
        execution: .shellScript,
        shortcut: UserCustomShortcut(
          key: "k",
          modifiers: UserCustomShortcutModifiers(command: true)
        )
      ),
    ]

    expectNoDifference(
      AppShortcuts.userOverrideConflicts(in: commands).map {
        "\($0.commandTitle)|\($0.commandShortcutDisplay)|\($0.appActionTitle)|\($0.appShortcutDisplay)"
      },
      [
        "Build|⌘⌃S|Toggle Left Sidebar|⌘⌃S"
      ]
    )
  }

  @Test func ghosttyCLIArgumentsKeepWorktreeUnbindsAndTabBinds() {
    let arguments = AppShortcuts.ghosttyCLIKeybindArguments

    for shortcut in AppShortcuts.worktreeSelection {
      #expect(arguments.contains(shortcut.ghosttyUnbindArgument))
      let tabIndex = shortcut.keyToken == "0" ? 10 : Int(shortcut.keyToken) ?? 0
      for argument in shortcut.ghosttyBindArguments(action: "goto_tab:\(tabIndex)") {
        #expect(arguments.contains(argument) == false)
      }
    }

    for (index, shortcut) in AppShortcuts.terminalTabSelection.enumerated() {
      let tabIndex = index == 9 ? 10 : index + 1
      for argument in shortcut.ghosttyBindArguments(action: "goto_tab:\(tabIndex)") {
        #expect(arguments.contains(argument))
      }
    }

    for argument in ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"].map({ "--keybind=ctrl+digit_\($0)=unbind" }) {
      #expect(arguments.contains(argument) == false)
    }

    for argument in [
      "--keybind=super+[=unbind",
      "--keybind=super+]=unbind",
      "--keybind=shift+super+[=unbind",
      "--keybind=shift+super+]=unbind",
    ] {
      #expect(arguments.contains(argument))
    }

    for argument in [
      "--keybind=super+d=unbind",
      "--keybind=super+shift+d=unbind",
    ] {
      #expect(arguments.contains(argument) == false)
    }
  }

  @Test func ghosttyCLIArgumentsIncludeTerminalNavigationBindings() {
    let arguments = AppShortcuts.ghosttyCLIKeybindArguments

    for argument in [
      "--keybind=shift+super+[=previous_tab",
      "--keybind=shift+super+]=next_tab",
      "--keybind=super+[=goto_split:previous",
      "--keybind=super+]=goto_split:next",
      "--keybind=alt+super+arrow_up=goto_split:up",
      "--keybind=alt+super+arrow_down=goto_split:down",
      "--keybind=alt+super+arrow_left=goto_split:left",
      "--keybind=alt+super+arrow_right=goto_split:right",
      "--keybind=alt+shift+super+f=toggle_split_zoom",
    ] {
      #expect(arguments.contains(argument))
    }
  }

  @Test func managedGhosttyActionOverrideRebindsAndUnbindsDefaults() {
    let overrides = KeybindingUserOverrideStore(
      overrides: [
        AppShortcuts.CommandID.selectNextTerminalTab: KeybindingUserOverride(
          binding: Keybinding(key: "t", modifiers: .init(command: true, shift: true))
        )
      ]
    )
    let resolved = KeybindingResolver.resolve(
      schema: .appResolverSchema(),
      userOverrides: overrides
    )

    let arguments = AppShortcuts.ghosttyCLIKeybindArguments(from: resolved)
    #expect(arguments.contains("--keybind=shift+super+t=unbind"))
    #expect(arguments.contains("--keybind=shift+super+]=unbind"))
    #expect(arguments.contains("--keybind=shift+super+t=next_tab"))
    #expect(arguments.contains("--keybind=shift+super+]=next_tab") == false)
  }

  @Test func worktreeSelectionOverrideDoesNotAffectTerminalTabBindings() {
    let overrides = KeybindingUserOverrideStore(
      overrides: [
        AppShortcuts.CommandID.selectWorktree1: KeybindingUserOverride(
          binding: Keybinding(key: "m", modifiers: .init(control: true))
        )
      ]
    )
    let resolved = KeybindingResolver.resolve(
      schema: .appResolverSchema(),
      userOverrides: overrides
    )

    let arguments = AppShortcuts.ghosttyCLIKeybindArguments(from: resolved)
    #expect(arguments.contains("--keybind=super+1=goto_tab:1"))
    #expect(arguments.contains("--keybind=super+digit_1=goto_tab:1"))
    #expect(arguments.contains("--keybind=ctrl+m=goto_tab:1") == false)
  }

  @Test func activeAgentsNavigationDisplayMergesDefaultBindings() {
    #expect(AppShortcuts.activeAgentsNavigationDisplay(in: .appDefaults) == "⌥⌃↑↓")
  }

  @Test func activeAgentsNavigationDisplayHiddenWhenEitherBindingCustomized() {
    let nextOverridden = KeybindingResolver.resolve(
      schema: .appResolverSchema(),
      userOverrides: KeybindingUserOverrideStore(
        overrides: [
          AppShortcuts.CommandID.selectNextActiveAgent: KeybindingUserOverride(
            binding: Keybinding(key: "j", modifiers: .init(command: true))
          )
        ]
      )
    )
    #expect(AppShortcuts.activeAgentsNavigationDisplay(in: nextOverridden) == nil)

    let previousOverridden = KeybindingResolver.resolve(
      schema: .appResolverSchema(),
      userOverrides: KeybindingUserOverrideStore(
        overrides: [
          AppShortcuts.CommandID.selectPreviousActiveAgent: KeybindingUserOverride(
            binding: Keybinding(key: "k", modifiers: .init(command: true))
          )
        ]
      )
    )
    #expect(AppShortcuts.activeAgentsNavigationDisplay(in: previousOverridden) == nil)
  }

  @Test func disabledManagedGhosttyActionKeepsDefaultUnboundWithoutBindingAction() {
    let overrides = KeybindingUserOverrideStore(
      overrides: [
        AppShortcuts.CommandID.selectNextTerminalPane: KeybindingUserOverride(
          binding: Keybinding(key: "k", modifiers: .init(command: true)),
          isEnabled: false
        )
      ]
    )
    let resolved = KeybindingResolver.resolve(
      schema: .appResolverSchema(),
      userOverrides: overrides
    )

    let arguments = AppShortcuts.ghosttyCLIKeybindArguments(from: resolved)
    #expect(arguments.contains("--keybind=super+]=unbind"))
    #expect(arguments.contains("--keybind=super+]=goto_split:next") == false)
    #expect(arguments.contains("--keybind=super+k=goto_split:next") == false)
  }

  @Test func resolverOverridePropagatesToMenuPaletteAndGhosttyArgs() {
    let overrides = KeybindingUserOverrideStore(
      overrides: [
        AppShortcuts.CommandID.openSettings: KeybindingUserOverride(
          binding: Keybinding(key: ";", modifiers: .init(command: true))
        )
      ]
    )
    let resolved = KeybindingResolver.resolve(
      schema: .appResolverSchema(),
      userOverrides: overrides
    )

    expectNoDifference(
      AppShortcuts.resolvedShortcut(for: AppShortcuts.CommandID.openSettings, in: resolved)?.display,
      "⌘;"
    )

    let paletteItem = CommandPaletteItem(
      id: "settings",
      title: "Open Settings",
      subtitle: nil,
      kind: .openSettings,
      category: .app,
      defaultSuggestion: false
    )
    expectNoDifference(paletteItem.appShortcutLabel(in: resolved), "⌘;")

    let arguments = AppShortcuts.ghosttyCLIKeybindArguments(from: resolved)
    #expect(arguments.contains("--keybind=super+;=unbind"))
    #expect(arguments.contains("--keybind=super+,=unbind") == false)
  }

  @Test func disabledOverrideRemovesShortcutFromMenuPaletteAndGhosttyArgs() {
    let overrides = KeybindingUserOverrideStore(
      overrides: [
        AppShortcuts.CommandID.openSettings: KeybindingUserOverride(
          binding: Keybinding(key: ";", modifiers: .init(command: true)),
          isEnabled: false
        )
      ]
    )
    let resolved = KeybindingResolver.resolve(
      schema: .appResolverSchema(),
      userOverrides: overrides
    )

    #expect(AppShortcuts.resolvedShortcut(for: AppShortcuts.CommandID.openSettings, in: resolved) == nil)
    #expect(resolved.display(for: AppShortcuts.CommandID.openSettings) == nil)

    let paletteItem = CommandPaletteItem(
      id: "settings",
      title: "Open Settings",
      subtitle: nil,
      kind: .openSettings,
      category: .app,
      defaultSuggestion: false
    )
    #expect(paletteItem.appShortcutLabel(in: resolved) == nil)

    let arguments = AppShortcuts.ghosttyCLIKeybindArguments(from: resolved)
    #expect(arguments.contains("--keybind=super+,=unbind") == false)
    #expect(arguments.contains("--keybind=super+;=unbind") == false)
  }

  @Test func disabledCanvasLayoutOverridesResolveToNil() {
    let overrides = KeybindingUserOverrideStore(
      overrides: [
        AppShortcuts.CommandID.arrangeCanvasCards: KeybindingUserOverride(
          binding: Keybinding(key: "r", modifiers: .init(command: true, option: true)),
          isEnabled: false
        ),
        AppShortcuts.CommandID.organizeCanvasCards: KeybindingUserOverride(
          binding: Keybinding(key: "g", modifiers: .init(command: true, option: true)),
          isEnabled: false
        ),
        AppShortcuts.CommandID.tileCanvasCards: KeybindingUserOverride(
          binding: Keybinding(key: "t", modifiers: .init(command: true, option: true)),
          isEnabled: false
        ),
      ]
    )
    let resolved = KeybindingResolver.resolve(
      schema: .appResolverSchema(),
      userOverrides: overrides
    )

    // When disabled the resolved shortcut must be nil so CanvasView's handler bails
    // instead of falling back to the app-default layout keys.
    #expect(AppShortcuts.resolvedShortcut(for: AppShortcuts.CommandID.arrangeCanvasCards, in: resolved) == nil)
    #expect(AppShortcuts.resolvedShortcut(for: AppShortcuts.CommandID.organizeCanvasCards, in: resolved) == nil)
    #expect(AppShortcuts.resolvedShortcut(for: AppShortcuts.CommandID.tileCanvasCards, in: resolved) == nil)
  }

  @Test func resolvedShortcutFallsBackToDefaultWhenCommandMissingInResolvedMap() {
    let resolved = ResolvedKeybindingMap(bindingsByCommandID: [:])

    expectNoDifference(
      AppShortcuts.resolvedShortcut(for: AppShortcuts.CommandID.openSettings, in: resolved)?.display,
      AppShortcuts.openSettings.display
    )
  }

  @Test func unsupportedResolvedBindingDoesNotFallbackToDefaultShortcut() {
    let overrides = KeybindingUserOverrideStore(
      overrides: [
        AppShortcuts.CommandID.openSettings: KeybindingUserOverride(
          binding: Keybinding(key: "space", modifiers: .init(command: true))
        )
      ]
    )
    let resolved = KeybindingResolver.resolve(
      schema: .appResolverSchema(),
      userOverrides: overrides
    )

    #expect(AppShortcuts.resolvedShortcut(for: AppShortcuts.CommandID.openSettings, in: resolved) == nil)

    let arguments = AppShortcuts.ghosttyCLIKeybindArguments(from: resolved)
    #expect(arguments.contains("--keybind=super+,=unbind") == false)
  }

  @Test func physicalDigitOverrideBehavesLikeNumberShortcut() {
    let overrides = KeybindingUserOverrideStore(
      overrides: [
        AppShortcuts.CommandID.openSettings: KeybindingUserOverride(
          binding: Keybinding(key: "digit_1", modifiers: .init(command: true))
        )
      ]
    )
    let resolved = KeybindingResolver.resolve(
      schema: .appResolverSchema(),
      userOverrides: overrides
    )

    expectNoDifference(
      AppShortcuts.resolvedShortcut(for: AppShortcuts.CommandID.openSettings, in: resolved)?.display,
      "⌘1"
    )

    let paletteItem = CommandPaletteItem(
      id: "settings",
      title: "Open Settings",
      subtitle: nil,
      kind: .openSettings,
      category: .app,
      defaultSuggestion: false
    )
    expectNoDifference(paletteItem.appShortcutLabel(in: resolved), "⌘1")

    let arguments = AppShortcuts.ghosttyCLIKeybindArguments(from: resolved)
    #expect(arguments.contains("--keybind=super+1=unbind"))
    #expect(arguments.contains("--keybind=super+,=unbind") == false)
  }
}
