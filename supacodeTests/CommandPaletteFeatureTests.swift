import ComposableArchitecture
import CustomDump
import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

@MainActor
struct CommandPaletteFeatureTests {
  @Test func commandPaletteItems_onlyGlobalWhenEmpty() {
    let items = CommandPaletteFeature.commandPaletteItems(from: RepositoriesFeature.State())
    var expectedIDs = [
      "global.check-for-updates",
      "global.open-settings",
      "global.open-repository",
      "global.new-workspace",
      "global.new-worktree",
      "global.refresh-worktrees",
      "global.jump-to-latest-unread",
      "global.view-archived-worktrees",
      "global.install-cli",
      "global.toggle-left-sidebar",
      "global.toggle-active-agents-panel",
      "global.toggle-canvas",
      "global.toggle-shelf",
    ]
    #if DEBUG
      expectedIDs.append(contentsOf: [
        "debug.toast.inProgress",
        "debug.toast.success",
        "debug.update.simulate-found",
        "debug.dock.notification-dot",
      ])
    #endif
    expectNoDifference(items.map(\.id), expectedIDs)
  }

  @Test func commandPaletteItems_includesShowDiffWhenWorktreeSelected() {
    let rootPath = "/tmp/repo-diff"
    let worktree = makeWorktree(id: "\(rootPath)/wt-1", name: "wt-1", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .worktree(worktree.id)

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    #expect(items.contains { $0.id == "global.show-diff" })
  }

  @Test func commandPaletteItems_includesCanvasCommandsInCanvasMode() {
    var state = RepositoriesFeature.State()
    state.selection = .canvas

    let ids = CommandPaletteFeature.commandPaletteItems(from: state).map(\.id)
    #expect(ids.contains("global.expand-canvas-card"))
    #expect(ids.contains("global.arrange-canvas-cards"))
    #expect(ids.contains("global.organize-canvas-cards"))
    #expect(ids.contains("global.select-all-canvas-cards"))
  }

  @Test func commandPaletteItems_omitsCanvasCommandsOutsideCanvas() {
    let ids = CommandPaletteFeature.commandPaletteItems(from: RepositoriesFeature.State()).map(\.id)
    #expect(!ids.contains("global.expand-canvas-card"))
    #expect(!ids.contains("global.arrange-canvas-cards"))
    #expect(!ids.contains("global.organize-canvas-cards"))
    #expect(!ids.contains("global.select-all-canvas-cards"))
  }

  @Test func commandPaletteItems_omitsShowDiffWithoutSelectedWorktree() {
    let items = CommandPaletteFeature.commandPaletteItems(from: RepositoriesFeature.State())
    #expect(!items.contains { $0.id == "global.show-diff" })
  }

  @Test func commandPaletteItems_includesWorktreeNavigationWhenWorktreeSelected() {
    let rootPath = "/tmp/repo-nav"
    let worktree = makeWorktree(id: "\(rootPath)/wt-1", name: "wt-1", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .worktree(worktree.id)

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    let ids = Set(items.map(\.id))
    #expect(ids.contains("global.reveal-in-finder"))
    #expect(ids.contains("global.copy-path"))
    #expect(ids.contains("global.reveal-in-sidebar"))
  }

  @Test func commandPaletteItems_omitsWorktreeNavigationWithoutSelectedWorktree() {
    let items = CommandPaletteFeature.commandPaletteItems(from: RepositoriesFeature.State())
    let ids = Set(items.map(\.id))
    #expect(!ids.contains("global.reveal-in-finder"))
    #expect(!ids.contains("global.copy-path"))
    #expect(!ids.contains("global.reveal-in-sidebar"))
  }

  @Test func commandPaletteItems_includesRunScriptWhenIdle() {
    let rootPath = "/tmp/repo-run"
    let worktree = makeWorktree(id: "\(rootPath)/wt-1", name: "wt-1", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .worktree(worktree.id)

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    let ids = Set(items.map(\.id))
    #expect(ids.contains("global.run-script"))
    #expect(!ids.contains("global.stop-run-script"))
  }

  @Test func commandPaletteItems_includesRunScriptForCanvasActionTarget() {
    let rootPath = "/tmp/repo-canvas-run"
    let worktree = makeWorktree(id: "\(rootPath)/wt-1", name: "wt-1", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .canvas

    let items = CommandPaletteFeature.commandPaletteItems(
      from: state,
      actionTargetWorktreeID: worktree.id
    )
    let ids = Set(items.map(\.id))
    #expect(ids.contains("global.run-script"))
    #expect(!ids.contains("global.rename-branch"))
    #expect(!ids.contains("global.toggle-pin-worktree"))
  }

  @Test func commandPaletteItems_includesStopScriptWhenRunning() {
    let rootPath = "/tmp/repo-run"
    let worktree = makeWorktree(id: "\(rootPath)/wt-1", name: "wt-1", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .worktree(worktree.id)

    let items = CommandPaletteFeature.commandPaletteItems(
      from: state,
      runScriptStatusByWorktreeID: [worktree.id: true]
    )
    let ids = Set(items.map(\.id))
    #expect(ids.contains("global.stop-run-script"))
    #expect(!ids.contains("global.run-script"))
  }

  @Test func commandPaletteItems_includesPinForNonPinnedWorktree() {
    let rootPath = "/tmp/repo-pin"
    let worktree = makeWorktree(id: "\(rootPath)/wt-1", name: "wt-1", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .worktree(worktree.id)

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    let pinItem = items.first { $0.id == "global.toggle-pin-worktree" }
    #expect(pinItem?.title == "Pin Worktree")
    #expect(pinItem?.kind == .togglePinWorktree(worktree.id, isCurrentlyPinned: false))
  }

  @Test func commandPaletteItems_includesUnpinForPinnedWorktree() {
    let rootPath = "/tmp/repo-pin"
    let worktree = makeWorktree(id: "\(rootPath)/wt-1", name: "wt-1", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .worktree(worktree.id)
    state.pinnedWorktreeIDs = [worktree.id]

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    let pinItem = items.first { $0.id == "global.toggle-pin-worktree" }
    #expect(pinItem?.title == "Unpin Worktree")
    #expect(pinItem?.kind == .togglePinWorktree(worktree.id, isCurrentlyPinned: true))
  }

  @Test func commandPaletteItems_includesRenameBranchForNonMainWorktree() {
    let rootPath = "/tmp/repo-rename"
    let worktree = makeWorktree(id: "\(rootPath)/wt-1", name: "wt-1", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .worktree(worktree.id)

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    let renameItem = items.first { $0.id == "global.rename-branch" }
    #expect(renameItem?.title == "Rename Branch")
    #expect(renameItem?.kind == .renameBranch)
    #expect(renameItem?.appShortcutCommandID == AppShortcuts.CommandID.renameBranch)
  }

  @Test func commandPaletteItems_omitsPinAndDeleteForMainWorktree() {
    let rootPath = "/tmp/repo-main"
    // Main worktree: workingDirectory == repositoryRootURL → Worktree.isMain == true
    let main = makeWorktree(
      id: rootPath,
      name: "main",
      repoRoot: rootPath,
      workingDirectory: rootPath
    )
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [main])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .worktree(main.id)

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    let ids = Set(items.map(\.id))
    #expect(!ids.contains("global.toggle-pin-worktree"))
    #expect(!ids.contains("global.delete-worktree"))
    // Rename Branch is still available on the main worktree — `git branch -m`
    // works on the main branch the same as any other.
    #expect(ids.contains("global.rename-branch"))
  }

  @Test func commandPaletteItems_includesDeleteWorktreeForNonMain() {
    let rootPath = "/tmp/repo-delete"
    let worktree = makeWorktree(id: "\(rootPath)/wt-1", name: "wt-1", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .worktree(worktree.id)

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    let deleteItem = items.first { $0.id == "global.delete-worktree" }
    #expect(deleteItem?.title == "Delete Worktree")
    #expect(deleteItem?.defaultSuggestion == false)
  }

  @Test func commandPaletteItems_includesCustomCommands() {
    let buildCmd = UserCustomCommand(
      id: "cmd-build",
      title: "Build",
      systemImage: "hammer",
      command: "make build",
      execution: .shellScript,
      shortcut: nil
    )
    let emptyCmd = UserCustomCommand(
      id: "cmd-empty",
      title: "Empty",
      systemImage: "terminal",
      command: "   ",
      execution: .shellScript,
      shortcut: nil
    )

    let items = CommandPaletteFeature.commandPaletteItems(
      from: RepositoriesFeature.State(),
      customCommands: [
        EffectiveCustomCommand(source: .repository, command: buildCmd),
        EffectiveCustomCommand(source: .repository, command: emptyCmd),
      ]
    )
    let ids = Set(items.map(\.id))
    #expect(ids.contains("custom-command.cmd-build"))
    // Commands with empty body are filtered out.
    #expect(!ids.contains("custom-command.cmd-empty"))

    let buildItem = items.first { $0.id == "custom-command.cmd-build" }
    #expect(buildItem?.title == "Build")
    #expect(buildItem?.subtitle == "Local custom command · Opens in a new tab")
    #expect(buildItem?.defaultSuggestion == false)
    #expect(
      buildItem?.kind
        == .runCustomCommand(
          .init(source: .repository, commandID: "cmd-build"),
          systemImage: "hammer"
        )
    )
  }

  @Test func commandPaletteItems_includesRepoSettingsForSelectedWorktree() {
    let rootPath = "/tmp/repo-settings"
    let worktree = makeWorktree(id: "\(rootPath)/wt-1", name: "wt-1", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .worktree(worktree.id)

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    let item = items.first { $0.id == "repo.\(repository.id).open-settings" }
    #expect(item?.title == "Repo Settings")
    #expect(item?.subtitle == "Repo")
    #expect(item?.kind == .openRepositorySettings(repository.id))
    #expect(item?.category == .app)
  }

  @Test func commandPaletteItems_includesRepoSettingsForSelectedRepository() {
    let rootPath = "/tmp/repo-settings-direct"
    let worktree = makeWorktree(id: "\(rootPath)/wt-1", name: "wt-1", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "RepoDirect", worktrees: [worktree])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .repository(repository.id)

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    #expect(items.contains { $0.id == "repo.\(repository.id).open-settings" })
  }

  @Test func commandPaletteItems_omitsRepoSettingsWithoutSelection() {
    let items = CommandPaletteFeature.commandPaletteItems(from: RepositoriesFeature.State())
    #expect(!items.contains { $0.id.hasPrefix("repo.") })
  }

  @Test func commandPaletteItems_customCommandSubtitleVariants() {
    let shellCmd = UserCustomCommand(
      id: "cmd-shell",
      title: "Shell",
      systemImage: "terminal",
      command: "make",
      execution: .shellScript,
      shortcut: nil
    )
    let inlineCmd = UserCustomCommand(
      id: "cmd-inline",
      title: "Inline",
      systemImage: "terminal",
      command: "ls",
      execution: .terminalInput,
      shortcut: nil
    )
    let splitCmd = UserCustomCommand(
      id: "cmd-split",
      title: "Split",
      systemImage: "terminal",
      command: "watch",
      execution: .split,
      splitDirection: .down,
      closeOnSuccess: false,
      shortcut: nil
    )

    let items = CommandPaletteFeature.commandPaletteItems(
      from: RepositoriesFeature.State(),
      customCommands: [shellCmd, inlineCmd, splitCmd].map {
        EffectiveCustomCommand(source: .repository, command: $0)
      }
    )

    #expect(
      items.first { $0.id == "custom-command.cmd-shell" }?.subtitle
        == "Local custom command · Opens in a new tab"
    )
    #expect(
      items.first { $0.id == "custom-command.cmd-inline" }?.subtitle
        == "Local custom command · Runs in the focused terminal"
    )
    #expect(
      items.first { $0.id == "custom-command.cmd-split" }?.subtitle
        == "Local custom command · Opens in a new split (down)"
    )
  }

  @Test func commandPaletteItems_includeJumpToLatestUnreadAction() {
    let items = CommandPaletteFeature.commandPaletteItems(from: RepositoriesFeature.State())
    let item = items.first { $0.id == "global.jump-to-latest-unread" }

    #expect(item?.title == "Jump to Latest Unread")
    #expect(item?.kind == .jumpToLatestUnread)
    #expect(item?.appShortcutCommandID == AppShortcuts.CommandID.jumpToLatestUnread)

    let filtered = CommandPaletteFeature.filterItems(items: items, query: "jump unread")
    #expect(filtered.first?.id == "global.jump-to-latest-unread")
  }

  @Test func commandPaletteItems_skipsPendingAndDeletingWorktrees() {
    let rootPath = "/tmp/repo"
    let keep = makeWorktree(id: "\(rootPath)/wt-keep", name: "keep", repoRoot: rootPath)
    let deleting = makeWorktree(
      id: "\(rootPath)/wt-delete",
      name: "delete",
      repoRoot: rootPath
    )
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [keep, deleting])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.deletingWorktreeIDs = [deleting.id]
    state.pendingWorktrees = [
      PendingWorktree(
        id: "\(rootPath)/wt-pending",
        repositoryID: repository.id,
        progress: WorktreeCreationProgress(
          stage: .creatingWorktree,
          worktreeName: "pending",
          baseRef: "origin/main",
          copyIgnored: false,
          copyUntracked: false
        )
      )
    ]

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    let ids = items.map(\.id)
    #expect(ids.contains("worktree.\(keep.id).select"))
    #expect(ids.contains { $0.contains(deleting.id) } == false)
    #expect(ids.contains { $0.contains("wt-pending") } == false)
  }

  @Test func commandPaletteItems_includeGhosttyCommandsWhenWorktreeSelected() {
    let rootPath = "/tmp/repo"
    let worktree = makeWorktree(id: rootPath, name: "repo", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .worktree(worktree.id)

    let items = CommandPaletteFeature.commandPaletteItems(
      from: state,
      ghosttyCommands: [
        GhosttyCommand(
          title: "Focus Split Right",
          description: "Focus the split to the right.",
          action: "goto_split:right",
          actionKey: "goto_split"
        )
      ]
    )

    let ghosttyItem = items.first {
      if case .ghosttyCommand(let action) = $0.kind {
        return action == "goto_split:right"
      }
      return false
    }

    #expect(ghosttyItem?.title == "Focus Split Right")
    #expect(ghosttyItem?.subtitle == "Focus the split to the right.")
  }

  @Test func commandPaletteItems_includeGhosttyCommandsForCanvasActionTarget() {
    let rootPath = "/tmp/repo-canvas-new-tab"
    let worktree = makeWorktree(id: "\(rootPath)/wt-1", name: "wt-1", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .canvas

    let items = CommandPaletteFeature.commandPaletteItems(
      from: state,
      actionTargetWorktreeID: worktree.id,
      ghosttyCommands: [
        GhosttyCommand(
          title: "New Tab",
          description: "Open a new tab.",
          action: "new_tab",
          actionKey: "new_tab"
        )
      ]
    )

    let ghosttyItem = items.first {
      if case .ghosttyCommand(let action) = $0.kind {
        return action == "new_tab"
      }
      return false
    }

    #expect(ghosttyItem?.title == "New Tab")
    #expect(ghosttyItem?.subtitle == "Open a new tab.")
  }

  @Test func commandPaletteItems_filtersUnsupportedGhosttyCommands() {
    let rootPath = "/tmp/repo"
    let worktree = makeWorktree(id: rootPath, name: "repo", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .worktree(worktree.id)

    let items = CommandPaletteFeature.commandPaletteItems(
      from: state,
      ghosttyCommands: [
        GhosttyCommand(
          title: "New Window",
          description: "Create a new window",
          action: "new_window",
          actionKey: "new_window"
        ),
        GhosttyCommand(
          title: "Next Window",
          description: "Go to next window",
          action: "goto_window:next",
          actionKey: "goto_window"
        ),
        GhosttyCommand(
          title: "Inspector",
          description: "Open inspector",
          action: "inspector",
          actionKey: "inspector"
        ),
        GhosttyCommand(
          title: "Focus Split Right",
          description: "Focus the split to the right.",
          action: "goto_split:right",
          actionKey: "goto_split"
        ),
      ]
    )

    let ghosttyActions = items.compactMap { item -> String? in
      if case .ghosttyCommand(let action) = item.kind {
        return action
      }
      return nil
    }

    #expect(ghosttyActions.contains("new_window") == false)
    #expect(ghosttyActions.contains("goto_window:next") == false)
    #expect(ghosttyActions.contains("inspector") == false)
    #expect(ghosttyActions.contains("goto_split:right"))
  }

  @Test func commandPaletteItems_omitGhosttyCommandsWithoutSelectedWorktree() {
    let items = CommandPaletteFeature.commandPaletteItems(
      from: RepositoriesFeature.State(),
      ghosttyCommands: [
        GhosttyCommand(
          title: "Focus Split Right",
          description: "",
          action: "goto_split:right",
          actionKey: "goto_split"
        )
      ]
    )

    #expect(
      items.contains {
        if case .ghosttyCommand = $0.kind {
          return true
        }
        return false
      } == false
    )
  }

  @Test func commandPaletteItems_omitsNewWorktreeForPlainFoldersOnly() {
    let repository = makeRepository(
      rootPath: "/tmp/folder",
      name: "Folder",
      kind: .plain,
      worktrees: []
    )
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .repository(repository.id)

    let items = CommandPaletteFeature.commandPaletteItems(from: state)

    #expect(items.contains(where: { $0.id == "global.new-worktree" }) == false)
  }

  @Test func commandPaletteItems_showsCodeHostActionWithoutPullRequest() {
    let rootPath = "/tmp/repo"
    let worktree = makeWorktree(id: rootPath, name: "repo", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .worktree(worktree.id)

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    let openItem = items.first {
      if case .openRepositoryOnCodeHost(let worktreeID) = $0.kind {
        return worktreeID == worktree.id
      }
      return false
    }

    #expect(openItem?.title == "Open Repository on Code Host")
    #expect(openItem?.subtitle == repository.name)

    let emptyQueryItems = CommandPaletteFeature.filterItems(items: items, query: "")
    #expect(emptyQueryItems.contains(where: { $0.id == openItem?.id }) == false)

    let searchedItems = CommandPaletteFeature.filterItems(items: items, query: "code host")
    #expect(searchedItems.contains(where: { $0.id == openItem?.id }))

    var githubState = state
    githubState.codeHostByRepositoryID[repository.id] = .github
    let githubItems = CommandPaletteFeature.commandPaletteItems(from: githubState)
    let githubOpenItem = githubItems.first {
      if case .openRepositoryOnCodeHost = $0.kind { return true }
      return false
    }
    #expect(githubOpenItem?.title == "Open Repository on GitHub")
  }

  @Test func commandPaletteItems_showsCodeHostActionForCanvasActionTarget() {
    let rootPath = "/tmp/repo-canvas-code-host"
    let worktree = makeWorktree(id: "\(rootPath)/wt-1", name: "feature/canvas", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .canvas
    state.codeHostByRepositoryID[repository.id] = .github
    state.worktreeInfoByID[worktree.id] = WorktreeInfoEntry(
      pullRequest: makePullRequest()
    )

    let items = CommandPaletteFeature.commandPaletteItems(
      from: state,
      actionTargetWorktreeID: worktree.id
    )
    let openItem = items.first {
      if case .openPullRequest(let worktreeID) = $0.kind {
        return worktreeID == worktree.id
      }
      return false
    }

    #expect(openItem?.title == "Open Pull Request on GitHub")
    #expect(openItem?.subtitle == "PR")
  }

  @Test func emptyQueryHidesChangeFocusedTabIcon() {
    let rootPath = "/tmp/repo"
    let worktree = makeWorktree(id: rootPath, name: "repo", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .worktree(worktree.id)

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    let changeIconItem = items.first {
      if case .changeFocusedTabIcon = $0.kind { return true }
      return false
    }
    #expect(changeIconItem != nil)

    let emptyQueryItems = CommandPaletteFeature.filterItems(items: items, query: "")
    #expect(emptyQueryItems.contains(where: { $0.id == changeIconItem?.id }) == false)

    let searchedItems = CommandPaletteFeature.filterItems(items: items, query: "tab icon")
    #expect(searchedItems.contains(where: { $0.id == changeIconItem?.id }))
  }

  @Test func keywordOnlyMatchSurfacesItem() {
    // "preferences" cannot fuzzy-match "Open Settings" (no p/r/f) so a match
    // only succeeds if keywords participate.
    let openSettings = makeItem(
      id: "global.open-settings",
      title: "Open Settings",
      subtitle: nil,
      kind: .openSettings,
      keywords: ["preferences"]
    )

    let result = CommandPaletteFeature.filterItems(items: [openSettings], query: "preferences")
    expectNoDifference(result.map(\.id), [openSettings.id])
  }

  @Test func keywordMatchRanksBelowDirectTitleMatch() {
    let openSettings = makeItem(
      id: "global.open-settings",
      title: "Open Settings",
      subtitle: nil,
      kind: .openSettings,
      keywords: ["preferences"]
    )
    let prefBranch = makeItem(
      id: "worktree.preferences.select",
      title: "preferences",
      subtitle: nil,
      kind: .worktreeSelect("wt-pref")
    )

    let result = CommandPaletteFeature.filterItems(items: [openSettings, prefBranch], query: "preferences")
    #expect(result.first?.id == prefBranch.id)
  }

  @Test func keywordMatchSurvivesMultiPieceQuery() {
    // "preferences" has to match via the keyword; "settings" matches the title.
    let openSettings = makeItem(
      id: "global.open-settings",
      title: "Open Settings",
      subtitle: nil,
      kind: .openSettings,
      keywords: ["preferences"]
    )

    let result = CommandPaletteFeature.filterItems(items: [openSettings], query: "preferences settings")
    expectNoDifference(result.map(\.id), [openSettings.id])
  }

  @Test func keywordMatchDoesNotIntroduceLabelHighlightsOutsideTitle() {
    let openSettings = makeItem(
      id: "global.open-settings",
      title: "Open Settings",
      subtitle: nil,
      kind: .openSettings,
      keywords: ["preferences"]
    )

    let result = CommandPaletteFeature.filterItems(items: [openSettings], query: "preferences")
    #expect(result.count == 1)
    // Sanity: the returned item is unchanged — no synthetic match positions leaked into the item.
    #expect(result.first?.title == openSettings.title)
  }

  // MARK: - suggestions()

  @Test func suggestionsEmptyInputReturnsEmptySections() {
    let result = CommandPaletteFeature.suggestions(items: [], recencyByID: [:], now: .now)
    #expect(result.recent.isEmpty)
    #expect(result.suggested.isEmpty)
  }

  @Test func suggestionsOnlyDefaultSuggestionItemsAppearWhenNoRecency() {
    let suggested = makeItem(
      id: "s",
      title: "Suggested",
      subtitle: nil,
      kind: .openSettings
    )
    let hidden = makeItem(
      id: "h",
      title: "Hidden",
      subtitle: nil,
      kind: .ghosttyCommand("focus_split")
    )
    let suggestedWithFlag = CommandPaletteItem(
      id: suggested.id,
      title: suggested.title,
      subtitle: suggested.subtitle,
      kind: suggested.kind,
      category: suggested.category,
      defaultSuggestion: true
    )

    let result = CommandPaletteFeature.suggestions(
      items: [suggestedWithFlag, hidden],
      recencyByID: [:],
      now: .now
    )
    #expect(result.recent.isEmpty)
    expectNoDifference(result.suggested.map(\.id), [suggestedWithFlag.id])
  }

  @Test func suggestionsRecentIncludesNonSuggestionItemsWithRecency() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let worktree = makeItem(
      id: "worktree.fox.select",
      title: "Repo / fox",
      subtitle: nil,
      kind: .worktreeSelect("wt-fox")
    )

    let result = CommandPaletteFeature.suggestions(
      items: [worktree],
      recencyByID: [worktree.id: now.timeIntervalSince1970 - 86_400],
      now: now
    )
    expectNoDifference(result.recent.map(\.id), [worktree.id])
    #expect(result.suggested.isEmpty)
  }

  @Test func suggestionsRecentSortedByRecencyDesc() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let recent = makeItem(id: "recent", title: "Recent", subtitle: nil, kind: .openSettings)
    let older = makeItem(id: "older", title: "Older", subtitle: nil, kind: .openRepository)

    let result = CommandPaletteFeature.suggestions(
      items: [older, recent],
      recencyByID: [
        recent.id: now.timeIntervalSince1970 - 86_400,
        older.id: now.timeIntervalSince1970 - 10 * 86_400,
      ],
      now: now
    )
    expectNoDifference(result.recent.map(\.id), [recent.id, older.id])
  }

  @Test func suggestionsDedupesRecentFromSuggested() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let appLevel = CommandPaletteItem(
      id: "global.open-settings",
      title: "Open Settings",
      subtitle: nil,
      kind: .openSettings,
      category: .app,
      defaultSuggestion: true
    )

    let result = CommandPaletteFeature.suggestions(
      items: [appLevel],
      recencyByID: [appLevel.id: now.timeIntervalSince1970 - 86_400],
      now: now
    )
    expectNoDifference(result.recent.map(\.id), [appLevel.id])
    #expect(result.suggested.isEmpty)
  }

  @Test func suggestionsCapsTotalAt8() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let items = (0..<12).map { index in
      makeItem(
        id: "item-\(index)",
        title: "Item \(index)",
        subtitle: nil,
        kind: .worktreeSelect("wt-\(index)")
      )
    }
    let recency = Dictionary(
      items.enumerated().map { idx, item in
        (item.id, now.timeIntervalSince1970 - TimeInterval(idx + 1) * 3600)
      },
      uniquingKeysWith: { first, _ in first }
    )

    let result = CommandPaletteFeature.suggestions(items: items, recencyByID: recency, now: now)
    #expect(result.recent.count + result.suggested.count == CommandPaletteSuggestions.maxItems)
  }

  @Test func suggestionsSuggestedSortsByPriorityTierThenDeclarationOrder() {
    let lowPriority = CommandPaletteItem(
      id: "low",
      title: "Low",
      subtitle: nil,
      kind: .openSettings,
      category: .app,
      defaultSuggestion: true,
      priorityTier: 0
    )
    let defaultPriorityFirst = CommandPaletteItem(
      id: "default-first",
      title: "Default First",
      subtitle: nil,
      kind: .openSettings,
      category: .app,
      defaultSuggestion: true,
      priorityTier: CommandPaletteItem.defaultPriorityTier
    )
    let defaultPrioritySecond = CommandPaletteItem(
      id: "default-second",
      title: "Default Second",
      subtitle: nil,
      kind: .openSettings,
      category: .app,
      defaultSuggestion: true,
      priorityTier: CommandPaletteItem.defaultPriorityTier
    )

    let result = CommandPaletteFeature.suggestions(
      items: [defaultPriorityFirst, defaultPrioritySecond, lowPriority],
      recencyByID: [:],
      now: .now
    )
    expectNoDifference(
      result.suggested.map(\.id),
      [lowPriority.id, defaultPriorityFirst.id, defaultPrioritySecond.id]
    )
  }

  @Test func filterItemsEmptyQueryHonorsDefaultSuggestionFlagOnly() {
    let suggested = CommandPaletteItem(
      id: "suggested",
      title: "Suggested",
      subtitle: nil,
      kind: .openSettings,
      category: .app,
      defaultSuggestion: true
    )
    let hidden = CommandPaletteItem(
      id: "hidden",
      title: "Hidden",
      subtitle: nil,
      kind: .openSettings,
      category: .app,
      defaultSuggestion: false
    )

    let result = CommandPaletteFeature.filterItems(items: [suggested, hidden], query: "")
    expectNoDifference(result.map(\.id), [suggested.id])
  }

  @Test func emptyQueryHidesGhosttyCommands() {
    let ghosttyItem = makeItem(
      id: "ghostty.goto_split:right|Focus Split Right",
      title: "Focus Split Right",
      subtitle: nil,
      kind: .ghosttyCommand("goto_split:right")
    )
    let prAction = makeItem(
      id: "pr.open",
      title: "Open PR on GitHub",
      subtitle: "PR title",
      kind: .openPullRequest("wt-1"),
      priorityTier: 2
    )

    let result = CommandPaletteFeature.filterItems(
      items: [ghosttyItem, prAction],
      query: ""
    )

    #expect(!result.contains { $0.id == ghosttyItem.id })
    #expect(result.contains { $0.id == prAction.id })
  }

  @Test func commandPaletteItems_omitsSubActionsForMainWorktree() {
    let rootPath = "/tmp/repo"
    let main = makeWorktree(
      id: rootPath,
      name: "repo",
      detail: "main",
      repoRoot: rootPath,
      workingDirectory: rootPath
    )
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [main])
    let items = CommandPaletteFeature.commandPaletteItems(
      from: RepositoriesFeature.State(repositories: [repository])
    )

    #expect(
      items.filter {
        if case .worktreeSelect = $0.kind {
          return true
        }
        return false
      }.count == 1
    )
  }

  @Test func commandPaletteItems_trimsDetailToNil() {
    let rootPath = "/tmp/repo"
    let worktree = makeWorktree(
      id: "\(rootPath)/wt-detail",
      name: "detail",
      detail: "   ",
      repoRoot: rootPath
    )
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    let items = CommandPaletteFeature.commandPaletteItems(
      from: RepositoriesFeature.State(repositories: [repository])
    )
    let selectItem = items.first {
      if case .worktreeSelect(let id) = $0.kind {
        return id == worktree.id
      }
      return false
    }
    #expect(selectItem?.subtitle == nil)
  }

  @Test func commandPaletteItems_keepsFullWorktreeName() {
    let rootPath = "/tmp/repo"
    let worktree = makeWorktree(
      id: "\(rootPath)/wt-path",
      name: "khoi/cache",
      detail: "main",
      repoRoot: rootPath
    )
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    let items = CommandPaletteFeature.commandPaletteItems(
      from: RepositoriesFeature.State(repositories: [repository])
    )
    let selectItem = items.first {
      if case .worktreeSelect(let id) = $0.kind {
        return id == worktree.id
      }
      return false
    }
    #expect(selectItem?.title == "Repo / khoi/cache")
  }

  @Test func commandPaletteItems_respectsRowOrderWithinRepository() {
    let rootPath = "/tmp/repo"
    let main = makeWorktree(
      id: rootPath,
      name: "repo",
      detail: "main",
      repoRoot: rootPath,
      workingDirectory: rootPath
    )
    let pinned = makeWorktree(
      id: "\(rootPath)/wt-pinned",
      name: "pinned",
      detail: "pinned",
      repoRoot: rootPath
    )
    let unpinned = makeWorktree(
      id: "\(rootPath)/wt-unpinned",
      name: "unpinned",
      detail: "unpinned",
      repoRoot: rootPath
    )
    let repository = makeRepository(
      rootPath: rootPath, name: "Repo",
      worktrees: [
        main,
        pinned,
        unpinned,
      ])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.pinnedWorktreeIDs = [pinned.id]
    state.worktreeOrderByRepository = [repository.id: [unpinned.id]]

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    let selectIDs = items.compactMap { item in
      if case .worktreeSelect(let id) = item.kind {
        return id
      }
      return nil
    }
    expectNoDifference(selectIDs, [main.id, pinned.id, unpinned.id])
  }

  @Test func commandPaletteItems_respectsRepositoryOrder() {
    let repoAPath = "/tmp/repo-a"
    let repoBPath = "/tmp/repo-b"
    let mainA = makeWorktree(
      id: repoAPath,
      name: "repo-a",
      detail: "main",
      repoRoot: repoAPath,
      workingDirectory: repoAPath
    )
    let mainB = makeWorktree(
      id: repoBPath,
      name: "repo-b",
      detail: "main",
      repoRoot: repoBPath,
      workingDirectory: repoBPath
    )
    let repoA = makeRepository(rootPath: repoAPath, name: "Repo A", worktrees: [mainA])
    let repoB = makeRepository(rootPath: repoBPath, name: "Repo B", worktrees: [mainB])
    var state = RepositoriesFeature.State(repositories: [repoA, repoB])
    state.repositoryRoots = [repoB.rootURL, repoA.rootURL]

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    let selectIDs = items.compactMap { item in
      if case .worktreeSelect(let id) = item.kind {
        return id
      }
      return nil
    }
    expectNoDifference(selectIDs, [mainB.id, mainA.id])
  }

  @Test func showsGlobalItemsWhenQueryEmpty() {
    let openSettings = makeItem(
      id: "global.open-settings",
      title: "Open Settings",
      subtitle: nil,
      kind: .openSettings
    )
    let newWorktree = makeItem(
      id: "global.new-worktree",
      title: "New Worktree",
      subtitle: nil,
      kind: .newWorktree
    )
    let selectFox = makeItem(
      id: "worktree.fox.select",
      title: "Repo / fox",
      subtitle: "main",
      kind: .worktreeSelect("wt-fox")
    )
    let deleteFox = makeItem(
      id: "worktree.fox.delete",
      title: "Delete Worktree",
      subtitle: "fox",
      kind: .deleteWorktree("wt-fox", "repo-fox")
    )
    let changeFoxIcon = makeItem(
      id: "worktree.fox.change-icon",
      title: "Change Tab Icon...",
      subtitle: "fox",
      kind: .changeFocusedTabIcon("wt-fox")
    )

    let result = CommandPaletteFeature.filterItems(
      items: [openSettings, newWorktree, selectFox, deleteFox, changeFoxIcon],
      query: ""
    )
    expectNoDifference(result.map(\.id), [openSettings.id, newWorktree.id])
  }

  @Test func queryKeepsSelectionWhenEmpty() async {
    var state = CommandPaletteFeature.State()
    state.query = "fox"
    state.selectedIndex = 1
    let store = TestStore(initialState: state) {
      CommandPaletteFeature()
    }

    await store.send(.binding(.set(\.query, ""))) {
      $0.query = ""
      $0.selectedIndex = 1
    }
  }

  @Test func queryRanksByFuzzyScoreAcrossAllItems() {
    let openSettings = makeItem(
      id: "global.open-settings",
      title: "Open Settings",
      subtitle: nil,
      kind: .openSettings
    )
    let selectSettings = makeItem(
      id: "worktree.settings.select",
      title: "Repo / settings",
      subtitle: "main",
      kind: .worktreeSelect("wt-settings")
    )

    expectNoDifference(
      CommandPaletteFeature.filterItems(items: [selectSettings, openSettings], query: "set"),
      [selectSettings, openSettings]
    )
  }

  @Test func fuzzyRanksPrefixAndShorterLabelFirst() {
    let short = makeItem(
      id: "worktree.set.select",
      title: "Set",
      subtitle: nil,
      kind: .worktreeSelect("wt-set")
    )
    let long = makeItem(
      id: "worktree.settings.select",
      title: "Settings",
      subtitle: nil,
      kind: .worktreeSelect("wt-settings")
    )

    expectNoDifference(
      CommandPaletteFeature.filterItems(items: [long, short], query: "set"),
      [short, long]
    )
  }

  @Test func fuzzyMatchesSubtitleWhenLabelDoesNot() {
    let item = makeItem(
      id: "worktree.fox.select",
      title: "Repo / fox",
      subtitle: "main",
      kind: .worktreeSelect("wt-fox")
    )

    expectNoDifference(
      CommandPaletteFeature.filterItems(items: [item], query: "main"),
      [item]
    )
  }

  @Test func fuzzyMatchesMultiplePieces() {
    let item = makeItem(
      id: "worktree.fox.select",
      title: "Repo / fox",
      subtitle: "main",
      kind: .worktreeSelect("wt-fox")
    )

    expectNoDifference(
      CommandPaletteFeature.filterItems(items: [item], query: "repo main"),
      [item]
    )
  }

  @Test func commandPaletteDraftActionRanksFirst() {
    let rootPath = "/tmp/repo"
    let worktree = makeWorktree(id: "\(rootPath)/wt-draft", name: "draft", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .worktree(worktree.id)
    state.worktreeInfoByID[worktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: makePullRequest(isDraft: true)
    )

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    let ordered = CommandPaletteFeature.filterItems(items: items, query: "")
    #expect(ordered.first?.title == "Mark PR Ready for Review")
  }

  @Test func commandPaletteFailingActionRanksFirst() {
    let rootPath = "/tmp/repo"
    let worktree = makeWorktree(id: "\(rootPath)/wt-failing", name: "failing", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .worktree(worktree.id)
    let failingCheck = GithubPullRequestStatusCheck(
      detailsUrl: "https://example.com/check/1",
      status: "COMPLETED",
      conclusion: "FAILURE",
      state: nil
    )
    state.worktreeInfoByID[worktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: makePullRequest(checks: [failingCheck])
    )

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    let ordered = CommandPaletteFeature.filterItems(items: items, query: "")
    #expect(ordered.first?.title == "Copy failing job URL")
  }

  @Test func commandPaletteFailingActionFallsBackToLogsWhenCheckURLMissing() {
    let rootPath = "/tmp/repo"
    let worktree = makeWorktree(id: "\(rootPath)/wt-failing", name: "failing", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .worktree(worktree.id)
    let failingCheck = GithubPullRequestStatusCheck(
      status: "COMPLETED",
      conclusion: "FAILURE",
      state: nil
    )
    state.worktreeInfoByID[worktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: makePullRequest(checks: [failingCheck])
    )

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    let ordered = CommandPaletteFeature.filterItems(items: items, query: "")
    #expect(ordered.first?.title == "Copy CI Failure Logs")
  }

  @Test func commandPaletteMergeActionRanksFirstWhenMergeable() {
    let rootPath = "/tmp/repo"
    let worktree = makeWorktree(id: "\(rootPath)/wt-merge", name: "merge", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .worktree(worktree.id)
    state.worktreeInfoByID[worktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: makePullRequest(
        mergeable: "MERGEABLE",
        mergeStateStatus: "CLEAN"
      )
    )

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    let ordered = CommandPaletteFeature.filterItems(items: items, query: "")
    #expect(ordered.first?.title == "Merge PR")
  }

  @Test func commandPaletteShowsCloseActionForOpenPullRequest() {
    let rootPath = "/tmp/repo"
    let worktree = makeWorktree(id: "\(rootPath)/wt-close", name: "close", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .worktree(worktree.id)
    state.worktreeInfoByID[worktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: makePullRequest(state: "OPEN")
    )

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    let closeItem = items.first(where: { $0.title == "Close PR" })
    #expect(closeItem != nil)
    #expect(closeItem?.subtitle == "PR")
    if case .some(.closePullRequest(let closeWorktreeID)) = closeItem?.kind {
      #expect(closeWorktreeID == worktree.id)
    } else {
      Issue.record("Expected close pull request command palette action")
    }
  }

  @Test func commandPaletteDoesNotShowCloseActionForMergedPullRequest() {
    let rootPath = "/tmp/repo"
    let worktree = makeWorktree(id: "\(rootPath)/wt-merged", name: "merged", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .worktree(worktree.id)
    state.worktreeInfoByID[worktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: makePullRequest(state: "MERGED")
    )

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    #expect(!items.contains(where: { $0.title == "Close PR" }))
  }

  @Test func commandPaletteDoesNotShowMergeActionWhenBlocked() {
    let rootPath = "/tmp/repo"
    let worktree = makeWorktree(id: "\(rootPath)/wt-blocked", name: "blocked", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .worktree(worktree.id)
    state.worktreeInfoByID[worktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: makePullRequest(
        mergeable: "UNKNOWN",
        mergeStateStatus: "BLOCKED"
      )
    )

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    #expect(!items.contains(where: { $0.title == "Merge PR" }))
  }

  @Test func recencyBreaksFuzzyTiesWithinGroup() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let recent = makeItem(
      id: "global.recent",
      title: "Open",
      subtitle: nil,
      kind: .openRepository
    )
    let older = makeItem(
      id: "global.older",
      title: "Open",
      subtitle: nil,
      kind: .openSettings
    )
    let recency: [CommandPaletteItem.ID: TimeInterval] = [
      recent.id: now.timeIntervalSince1970 - 1 * 86_400,
      older.id: now.timeIntervalSince1970 - 10 * 86_400,
    ]

    expectNoDifference(
      CommandPaletteFeature.filterItems(
        items: [older, recent],
        query: "open",
        recencyByID: recency,
        now: now
      ),
      [recent, older]
    )
  }

  @Test func supacodeItemsBeatGhosttyItemsWhenScoresTie() {
    let supacodeItem = makeItem(
      id: "global.open-settings",
      title: "Open Settings",
      subtitle: nil,
      kind: .openSettings
    )
    let ghosttyItem = makeItem(
      id: "ghostty.open-settings|Open Settings",
      title: "Open Settings",
      subtitle: nil,
      kind: .ghosttyCommand("open_settings"),
      priorityTier: CommandPaletteItem.defaultPriorityTier + 100
    )

    expectNoDifference(
      CommandPaletteFeature.filterItems(
        items: [ghosttyItem, supacodeItem],
        query: "open settings"
      ),
      [supacodeItem, ghosttyItem]
    )
  }

  // MARK: - Unified Ranking Tests

  @Test func worktreeOutranksGlobalWhenBetterMatch() {
    let checkForUpdates = makeItem(
      id: "global.check-for-updates",
      title: "Check for Updates",
      subtitle: nil,
      kind: .checkForUpdates
    )
    let worktreeFox = makeItem(
      id: "worktree.fox.select",
      title: "Repo / fox",
      subtitle: nil,
      kind: .worktreeSelect("wt-fox")
    )

    expectNoDifference(
      CommandPaletteFeature.filterItems(items: [checkForUpdates, worktreeFox], query: "fox"),
      [worktreeFox]
    )
  }

  @Test func worktreeExactPrefixOutranksGlobalSubstringMatch() {
    let openSettings = makeItem(
      id: "global.open-settings",
      title: "Open Settings",
      subtitle: nil,
      kind: .openSettings
    )
    let worktreeOpen = makeItem(
      id: "worktree.open.select",
      title: "open",
      subtitle: nil,
      kind: .worktreeSelect("wt-open")
    )

    let result = CommandPaletteFeature.filterItems(
      items: [openSettings, worktreeOpen],
      query: "open"
    )
    #expect(result.first?.id == worktreeOpen.id)
  }

  @Test func globalAndWorktreeItemsInterleavedByScore() {
    let openRepo = makeItem(
      id: "global.open-repository",
      title: "Open Repository",
      subtitle: nil,
      kind: .openRepository
    )
    let worktreeRepo = makeItem(
      id: "worktree.repo.select",
      title: "repo",
      subtitle: nil,
      kind: .worktreeSelect("wt-repo")
    )
    let refreshWorktrees = makeItem(
      id: "global.refresh-worktrees",
      title: "Refresh Worktrees",
      subtitle: nil,
      kind: .refreshWorktrees
    )

    let result = CommandPaletteFeature.filterItems(
      items: [openRepo, worktreeRepo, refreshWorktrees],
      query: "repo"
    )

    #expect(result.contains { $0.id == worktreeRepo.id })
    #expect(result.contains { $0.id == openRepo.id })
    #expect(!result.contains { $0.id == refreshWorktrees.id })
  }

  @Test func nonMatchingItemsExcludedRegardlessOfType() {
    let checkForUpdates = makeItem(
      id: "global.check-for-updates",
      title: "Check for Updates",
      subtitle: nil,
      kind: .checkForUpdates
    )
    let worktreeFox = makeItem(
      id: "worktree.fox.select",
      title: "Repo / fox",
      subtitle: nil,
      kind: .worktreeSelect("wt-fox")
    )

    expectNoDifference(
      CommandPaletteFeature.filterItems(items: [checkForUpdates, worktreeFox], query: "zzz"),
      []
    )
  }

  @Test func multipleWorktreesCanAppearBeforeGlobalItems() {
    let openSettings = makeItem(
      id: "global.open-settings",
      title: "Open Settings",
      subtitle: nil,
      kind: .openSettings
    )
    let worktreeAlpha = makeItem(
      id: "worktree.alpha.select",
      title: "set",
      subtitle: nil,
      kind: .worktreeSelect("wt-alpha")
    )
    let worktreeBeta = makeItem(
      id: "worktree.beta.select",
      title: "sett",
      subtitle: nil,
      kind: .worktreeSelect("wt-beta")
    )

    let result = CommandPaletteFeature.filterItems(
      items: [openSettings, worktreeAlpha, worktreeBeta],
      query: "set"
    )

    #expect(result.count == 3)
    #expect(result[0].id == worktreeAlpha.id)
    #expect(result[1].id == worktreeBeta.id)
  }

  @Test func priorityTierBreaksTiesAcrossItemTypes() {
    let prAction = makeItem(
      id: "pr.merge",
      title: "Merge PR",
      subtitle: "Ready",
      kind: .mergePullRequest("wt-1"),
      priorityTier: 0
    )
    let worktreeMerge = makeItem(
      id: "worktree.merge.select",
      title: "Merge",
      subtitle: nil,
      kind: .worktreeSelect("wt-merge")
    )

    let result = CommandPaletteFeature.filterItems(
      items: [worktreeMerge, prAction],
      query: "merge"
    )

    #expect(result.count == 2)
    let prIndex = result.firstIndex { $0.id == prAction.id }!
    let wtIndex = result.firstIndex { $0.id == worktreeMerge.id }!
    #expect(wtIndex < prIndex)
  }

  @Test func recencyBreaksTiesAcrossItemTypes() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let globalItem = makeItem(
      id: "global.open-settings",
      title: "Open Settings",
      subtitle: nil,
      kind: .openSettings
    )
    let worktreeItem = makeItem(
      id: "worktree.settings.select",
      title: "Repo / settings",
      subtitle: nil,
      kind: .worktreeSelect("wt-settings")
    )
    let recency: [CommandPaletteItem.ID: TimeInterval] = [
      worktreeItem.id: now.timeIntervalSince1970 - 1 * 86_400,
      globalItem.id: now.timeIntervalSince1970 - 20 * 86_400,
    ]

    let result = CommandPaletteFeature.filterItems(
      items: [globalItem, worktreeItem],
      query: "settings",
      recencyByID: recency,
      now: now
    )

    #expect(result.first?.id == worktreeItem.id)
  }

  @Test func worktreeWithLabelMatchOutranksGlobalWithDescriptionMatch() {
    let globalItem = makeItem(
      id: "global.pr.open",
      title: "Open PR on GitHub",
      subtitle: "deploy-fixes",
      kind: .openPullRequest("wt-1")
    )
    let worktreeItem = makeItem(
      id: "worktree.deploy.select",
      title: "Repo / deploy-fixes",
      subtitle: nil,
      kind: .worktreeSelect("wt-deploy")
    )

    let result = CommandPaletteFeature.filterItems(
      items: [globalItem, worktreeItem],
      query: "deploy"
    )

    #expect(result.first?.id == worktreeItem.id)
  }

  @Test func shorterWorktreeLabelWinsOverLongerGlobalLabel() {
    let globalItem = makeItem(
      id: "global.new-worktree",
      title: "New Worktree",
      subtitle: nil,
      kind: .newWorktree
    )
    let worktreeItem = makeItem(
      id: "worktree.new.select",
      title: "new",
      subtitle: nil,
      kind: .worktreeSelect("wt-new")
    )

    let result = CommandPaletteFeature.filterItems(
      items: [globalItem, worktreeItem],
      query: "new"
    )

    #expect(result.first?.id == worktreeItem.id)
  }

  @Test func emptyQueryShowsSuggestionItemsAndHidesContextualOnes() {
    let checkForUpdates = makeItem(
      id: "global.check-for-updates",
      title: "Check for Updates",
      subtitle: nil,
      kind: .checkForUpdates
    )
    let worktreeFox = makeItem(
      id: "worktree.fox.select",
      title: "Repo / fox",
      subtitle: nil,
      kind: .worktreeSelect("wt-fox")
    )
    let prAction = makeItem(
      id: "pr.open",
      title: "Open PR on GitHub",
      subtitle: "PR title",
      kind: .openPullRequest("wt-1"),
      priorityTier: 2
    )

    let result = CommandPaletteFeature.filterItems(
      items: [checkForUpdates, worktreeFox, prAction],
      query: ""
    )

    #expect(result.contains { $0.id == checkForUpdates.id })
    #expect(!result.contains { $0.id == worktreeFox.id })
    #expect(result.contains { $0.id == prAction.id })
  }

  @Test func whitespaceOnlyQueryTreatedAsEmpty() {
    let checkForUpdates = makeItem(
      id: "global.check-for-updates",
      title: "Check for Updates",
      subtitle: nil,
      kind: .checkForUpdates
    )
    let worktreeFox = makeItem(
      id: "worktree.fox.select",
      title: "Repo / fox",
      subtitle: nil,
      kind: .worktreeSelect("wt-fox")
    )

    let emptyResult = CommandPaletteFeature.filterItems(
      items: [checkForUpdates, worktreeFox],
      query: ""
    )
    let whitespaceResult = CommandPaletteFeature.filterItems(
      items: [checkForUpdates, worktreeFox],
      query: "   "
    )

    expectNoDifference(emptyResult, whitespaceResult)
  }

  @Test func inputOrderDoesNotAffectScoreBasedRanking() {
    let globalItem = makeItem(
      id: "global.open-settings",
      title: "Open Settings",
      subtitle: nil,
      kind: .openSettings
    )
    let worktreeItem = makeItem(
      id: "worktree.open.select",
      title: "open",
      subtitle: nil,
      kind: .worktreeSelect("wt-open")
    )

    let resultAB = CommandPaletteFeature.filterItems(
      items: [globalItem, worktreeItem],
      query: "open"
    )
    let resultBA = CommandPaletteFeature.filterItems(
      items: [worktreeItem, globalItem],
      query: "open"
    )

    #expect(resultAB.first?.id == resultBA.first?.id)
  }

  @Test func activateDispatchesDelegateAndUpdatesRecency() async {
    var state = CommandPaletteFeature.State()
    state.isPresented = true
    state.query = "bear"
    state.selectedIndex = 1
    let item = makeItem(
      id: "global.open-repository",
      title: "Open Repository",
      subtitle: nil,
      kind: .openRepository
    )
    let store = TestStore(initialState: state) {
      CommandPaletteFeature()
    }
    let now = Date(timeIntervalSince1970: 1_234_567)
    store.dependencies.date = .constant(now)

    await store.send(.activateItem(item)) {
      $0.isPresented = false
      $0.query = ""
      $0.selectedIndex = nil
      $0.recencyByItemID[item.id] = now.timeIntervalSince1970
    }
    await store.receive(.delegate(.openRepository))
  }

  @Test func activateGhosttyCommandDispatchesDelegate() async {
    let now = Date(timeIntervalSince1970: 7_654_321)
    let item = makeItem(
      id: "ghostty.goto_split:right|Focus Split Right",
      title: "Focus Split Right",
      subtitle: nil,
      kind: .ghosttyCommand("goto_split:right")
    )
    var state = CommandPaletteFeature.State()
    state.isPresented = true
    let store = TestStore(initialState: state) {
      CommandPaletteFeature()
    }
    store.dependencies.date = .constant(now)

    await store.send(.activateItem(item)) {
      $0.isPresented = false
      $0.query = ""
      $0.selectedIndex = nil
      $0.recencyByItemID[item.id] = now.timeIntervalSince1970
    }
    await store.receive(.delegate(.ghosttyCommand("goto_split:right")))
  }

  @Test func activateOutgoingChangesDispatchesDelegate() async {
    let now = Date(timeIntervalSince1970: 7_654_322)
    let item = makeItem(
      id: CommandPaletteItemID.globalOutgoingChanges,
      title: "Outgoing Changes",
      subtitle: nil,
      kind: .outgoingChanges
    )
    var state = CommandPaletteFeature.State()
    state.isPresented = true
    let store = TestStore(initialState: state) {
      CommandPaletteFeature()
    }
    store.dependencies.date = .constant(now)

    await store.send(.activateItem(item)) {
      $0.isPresented = false
      $0.query = ""
      $0.selectedIndex = nil
      $0.recencyByItemID[item.id] = now.timeIntervalSince1970
    }
    await store.receive(.delegate(.showOutgoingChanges))
  }
}

private func makeWorktree(
  id: String,
  name: String,
  detail: String = "detail",
  repoRoot: String,
  workingDirectory: String? = nil
) -> Worktree {
  Worktree(
    id: id,
    name: name,
    detail: detail,
    workingDirectory: URL(fileURLWithPath: workingDirectory ?? id),
    repositoryRootURL: URL(fileURLWithPath: repoRoot)
  )
}

private func makeRepository(
  rootPath: String,
  name: String,
  kind: Repository.Kind = .git,
  worktrees: [Worktree]
) -> Repository {
  let rootURL = URL(fileURLWithPath: rootPath)
  return Repository(
    id: rootURL.path(percentEncoded: false),
    rootURL: rootURL,
    name: name,
    kind: kind,
    worktrees: IdentifiedArray(uniqueElements: worktrees)
  )
}

private func makeItem(
  id: String,
  title: String,
  subtitle: String?,
  kind: CommandPaletteItem.Kind,
  keywords: [String] = [],
  priorityTier: Int = CommandPaletteItem.defaultPriorityTier
) -> CommandPaletteItem {
  CommandPaletteItem(
    id: id,
    title: title,
    subtitle: subtitle,
    kind: kind,
    category: testCategory(for: kind),
    defaultSuggestion: testDefaultSuggestion(for: kind),
    keywords: keywords,
    priorityTier: priorityTier
  )
}

private func testCategory(for kind: CommandPaletteItem.Kind) -> CommandPaletteItem.Category {
  switch kind {
  case .checkForUpdates, .openSettings, .openRepository, .newWorkspace, .installCLI,
    .openRepositorySettings:
    return .app
  case .newWorktree, .refreshWorktrees, .viewArchivedWorktrees,
    .changeFocusedTabIcon,
    .runScript, .stopRunScript, .togglePinWorktree,
    .renameBranch, .deleteWorktree, .runCustomCommand:
    return .worktree
  case .jumpToLatestUnread, .worktreeSelect, .revealInFinder, .copyPath, .revealInSidebar:
    return .navigation
  case .openPullRequest, .openRepositoryOnCodeHost, .markPullRequestReady,
    .mergePullRequest, .closePullRequest, .copyFailingJobURL, .copyCiFailureLogs,
    .rerunFailedJobs, .openFailingCheckDetails:
    return .pullRequest
  case .ghosttyCommand, .launchAgentProfile, .runWorkflow:
    return .terminal
  case .toggleLeftSidebar, .toggleActiveAgentsPanel, .toggleCanvas,
    .expandCanvasCard, .arrangeCanvasCards, .organizeCanvasCards, .tileCanvasCards, .selectAllCanvasCards,
    .toggleShelf, .showDiff, .outgoingChanges:
    return .view
  #if DEBUG
    case .debugTestToast, .debugSimulateUpdateFound, .debugLightDockNotificationDot:
      return .debug
  #endif
  }
}

private func testDefaultSuggestion(for kind: CommandPaletteItem.Kind) -> Bool {
  switch kind {
  case .checkForUpdates, .openSettings, .openRepository, .newWorkspace, .installCLI,
    .newWorktree, .refreshWorktrees, .viewArchivedWorktrees, .jumpToLatestUnread,
    .openPullRequest, .markPullRequestReady, .mergePullRequest, .closePullRequest,
    .copyFailingJobURL, .copyCiFailureLogs, .rerunFailedJobs, .openFailingCheckDetails,
    .toggleLeftSidebar, .toggleActiveAgentsPanel, .toggleCanvas,
    .expandCanvasCard, .arrangeCanvasCards, .organizeCanvasCards, .tileCanvasCards, .selectAllCanvasCards,
    .toggleShelf, .showDiff, .outgoingChanges,
    .revealInFinder, .copyPath, .revealInSidebar,
    .runScript, .stopRunScript, .togglePinWorktree, .renameBranch,
    .openRepositorySettings:
    return true
  case .worktreeSelect, .changeFocusedTabIcon,
    .ghosttyCommand, .openRepositoryOnCodeHost,
    .deleteWorktree, .runCustomCommand, .launchAgentProfile, .runWorkflow:
    return false
  #if DEBUG
    case .debugTestToast, .debugSimulateUpdateFound, .debugLightDockNotificationDot:
      return true
  #endif
  }
}

private func makePullRequest(
  state: String = "OPEN",
  isDraft: Bool = false,
  reviewDecision: String? = nil,
  mergeable: String? = nil,
  mergeStateStatus: String? = nil,
  checks: [GithubPullRequestStatusCheck] = []
) -> GithubPullRequest {
  GithubPullRequest(
    number: 1,
    title: "PR",
    state: state,
    additions: 0,
    deletions: 0,
    isDraft: isDraft,
    reviewDecision: reviewDecision,
    mergeable: mergeable,
    mergeStateStatus: mergeStateStatus,
    updatedAt: nil,
    url: "https://example.com/pull/1",
    headRefName: "feature",
    baseRefName: "main",
    commitsCount: 1,
    authorLogin: "khoi",
    statusCheckRollup: checks.isEmpty ? nil : GithubPullRequestStatusCheckRollup(checks: checks)
  )
}
